# frozen_string_literal: true

require 'test_helper'
require_relative '../app/daemon'

class DaemonTraktRefreshTest < Minitest::Test
  def setup
    reset_librarian_state!
    @environment = build_stubbed_environment
    MediaLibrarian.application = @environment.application
    Daemon.configure(app: @environment.application)
    Daemon.instance_variable_set(:@trakt_refresh_disabled, false)
  end

  def teardown
    Daemon.instance_variable_set(:@trakt_refresh_disabled, false)
    MediaLibrarian.application = nil
    @environment&.cleanup
  end

  def test_refreshes_expiring_trakt_token_and_persists
    token = build_token('old', expires_in: 120, created_at: Time.now.to_i - 4_000)
    refreshed = build_token('new', expires_in: 3_600, created_at: Time.now.to_i)
    trakt = build_trakt_stub(token, [refreshed, :ok])

    app = @environment.application
    app.trakt_account = 'account'
    app.trakt = trakt
    app.db = CaptureDb.new

    Daemon.send(:refresh_trakt_token)

    assert_equal({ 'account' => 'account' }.merge(refreshed), app.db.last_insert)
    assert_equal 1, trakt.account.refresh_calls
  end

  def test_skips_refresh_when_token_not_due
    token = build_token('valid', expires_in: 10_000, created_at: Time.now.to_i)
    trakt = build_trakt_stub(token, [token, :ok])

    app = @environment.application
    app.trakt_account = 'account'
    app.trakt = trakt
    app.db = CaptureDb.new

    Daemon.send(:refresh_trakt_token)

    assert_nil app.db.last_insert
    assert_equal 0, trakt.account.refresh_calls
  end

  def test_invalid_grant_disables_refresh_and_logs_once
    token = build_token('old', expires_in: 120, created_at: Time.now.to_i - 4_000)
    trakt = build_trakt_stub(token, [nil, :invalid_grant])

    app = @environment.application
    app.trakt_account = 'account'
    app.trakt = trakt
    app.db = CaptureDb.new

    Daemon.send(:refresh_trakt_token)
    Daemon.send(:refresh_trakt_token)
    Daemon.send(:refresh_trakt_token)

    assert_nil app.db.last_insert
    assert_equal 1, trakt.account.refresh_calls
    warnings = app.speaker.messages.select { |m| m.is_a?(String) && m.include?('re-authorization required') }
    assert_equal 1, warnings.size
  end

  def test_transient_refresh_failure_keeps_retrying
    token = build_token('old', expires_in: 120, created_at: Time.now.to_i - 4_000)
    trakt = build_trakt_stub(token, [nil, :transient])

    app = @environment.application
    app.trakt_account = 'account'
    app.trakt = trakt
    app.db = CaptureDb.new

    Daemon.send(:refresh_trakt_token)
    Daemon.send(:refresh_trakt_token)

    assert_nil app.db.last_insert
    assert_equal 2, trakt.account.refresh_calls
  end

  def test_legacy_account_with_expired_token_never_calls_access_token
    token = build_token('old', expires_in: 120, created_at: Time.now.to_i - 4_000)
    trakt = build_legacy_trakt_stub(token)

    app = @environment.application
    app.trakt_account = 'account'
    app.trakt = trakt
    app.db = CaptureDb.new

    Daemon.send(:refresh_trakt_token)

    assert_equal 0, trakt.account.refresh_calls
    assert_nil app.db.last_insert
  end

  def test_legacy_account_refreshes_token_still_valid
    token = build_token('old', expires_in: 3_600, created_at: Time.now.to_i - 3_400)
    refreshed = build_token('new', expires_in: 3_600, created_at: Time.now.to_i)
    trakt = build_legacy_trakt_stub(token, refreshed)

    app = @environment.application
    app.trakt_account = 'account'
    app.trakt = trakt
    app.db = CaptureDb.new

    Daemon.send(:refresh_trakt_token)

    assert_equal 1, trakt.account.refresh_calls
    assert_equal({ 'account' => 'account' }.merge(refreshed), app.db.last_insert)
  end

  def test_adopts_newer_token_from_db_and_reenables_refresh
    token = build_token('old', expires_in: 120, created_at: Time.now.to_i - 4_000)
    stored = build_token('fresh', expires_in: 604_800, created_at: Time.now.to_i)
    trakt = build_trakt_stub(token, [nil, :invalid_grant])

    app = @environment.application
    app.trakt_account = 'account'
    app.trakt = trakt
    app.db = CaptureDb.new

    Daemon.send(:refresh_trakt_token)
    assert Daemon.instance_variable_get(:@trakt_refresh_disabled)

    app.db.stored_rows = [stored.merge('account' => 'account')]
    Daemon.send(:refresh_trakt_token)

    assert_equal stored, trakt.token
    refute Daemon.instance_variable_get(:@trakt_refresh_disabled)
  end

  private

  def build_token(access_token, expires_in:, created_at: Time.now.to_i)
    {
      'access_token' => access_token,
      'refresh_token' => 'refresh',
      'created_at' => created_at,
      'expires_in' => expires_in
    }
  end

  def build_trakt_stub(initial_token, refresh_result)
    account = Struct.new(:trakt, :refresh_result, :refresh_calls) do
      def refresh_access_token(*_args)
        self.refresh_calls += 1
        refreshed, status = refresh_result
        trakt.token = refreshed if refreshed
        [refreshed, status]
      end
    end.new(nil, refresh_result, 0)

    trakt = Struct.new(:token, :account).new(initial_token.dup, account)
    account.trakt = trakt
    trakt
  end

  def build_legacy_trakt_stub(initial_token, refreshed_token = nil)
    account = Struct.new(:trakt, :refreshed_token, :refresh_calls) do
      def access_token
        self.refresh_calls += 1
        trakt.token = refreshed_token if refreshed_token
        refreshed_token && refreshed_token['access_token']
      end
    end.new(nil, refreshed_token, 0)

    trakt = Struct.new(:token, :account).new(initial_token.dup, account)
    account.trakt = trakt
    trakt
  end

  class CaptureDb
    attr_reader :last_insert
    attr_accessor :stored_rows

    def initialize
      @stored_rows = []
    end

    def get_rows(_table, _conditions = {})
      @stored_rows
    end

    def insert_row(_table, values, _replace)
      @last_insert = values
    end
  end
end
