# frozen_string_literal: true

require 'test_helper'
require_relative '../app/daemon'

class DaemonTraktRefreshTest < Minitest::Test
  def setup
    reset_librarian_state!
    @environment = build_stubbed_environment
    MediaLibrarian.application = @environment.application
    Daemon.configure(app: @environment.application)
  end

  def teardown
    MediaLibrarian.application = nil
    @environment&.cleanup
  end

  def test_refreshes_expiring_trakt_token_and_persists
    token = build_token('old', expires_in: 120, created_at: Time.now.to_i - 4_000)
    refreshed = build_token('new', expires_in: 3_600, created_at: Time.now.to_i)
    trakt = build_trakt_stub(token, refreshed)

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
    trakt = build_trakt_stub(token, token)

    app = @environment.application
    app.trakt_account = 'account'
    app.trakt = trakt
    app.db = CaptureDb.new

    Daemon.send(:refresh_trakt_token)

    assert_nil app.db.last_insert
    assert_equal 0, trakt.account.refresh_calls
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

  def build_trakt_stub(initial_token, refreshed_token)
    account = Struct.new(:trakt, :refreshed_token, :refresh_calls) do
      def access_token
        self.refresh_calls += 1
        trakt.token = refreshed_token
        refreshed_token['access_token']
      end
    end.new(nil, refreshed_token, 0)

    trakt = Struct.new(:token, :account).new(initial_token.dup, account)
    account.trakt = trakt
    trakt
  end

  class CaptureDb
    attr_reader :last_insert

    def insert_row(_table, values, _replace)
      @last_insert = values
    end
  end
end
