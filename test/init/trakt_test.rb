# frozen_string_literal: true

require 'test_helper'
require 'trakt'

class InitTraktTest < Minitest::Test
  def setup
    reset_librarian_state!
    @environment = build_stubbed_environment
    MediaLibrarian.application = @environment.application
  end

  def teardown
    MediaLibrarian.application = nil
    if MediaLibrarian::Boot.instance_variable_defined?(:@application)
      MediaLibrarian::Boot.remove_instance_variable(:@application)
    end
    @environment&.cleanup
  end

  def test_keeps_stored_token_when_expires_at_is_nil
    app = @environment.application
    @environment.container.config = {
      'trakt' => { 'account_id' => 'test', 'client_id' => 'client_id', 'client_secret' => '' }
    }
    app.db = FakeDb.new([
                          {
                            account: 'test',
                            access_token: 'token',
                            refresh_token: 'refresh',
                            created_at: 1_234_567_890,
                            expires_in: 3600,
                            expires_at: nil
                          }
                        ])

    load_trakt_init(app)

    refute token_missing_message?(app), 'A valid token with nil expires_at should be kept'
  end

  def test_rejects_stored_token_when_access_token_is_nil
    app = @environment.application
    @environment.container.config = {
      'trakt' => { 'account_id' => 'test', 'client_id' => 'client_id', 'client_secret' => '' }
    }
    app.db = FakeDb.new([
                          {
                            account: 'test',
                            access_token: nil,
                            refresh_token: 'refresh',
                            created_at: 1_234_567_890,
                            expires_in: 3600,
                            expires_at: nil
                          }
                        ])

    load_trakt_init(app)

    assert token_missing_message?(app), 'A token with nil access_token must be rejected'
  end

  private

  def load_trakt_init(app)
    MediaLibrarian::Boot.stub(:application, app) do
      load File.expand_path('../../init/trakt.rb', __dir__)
    end
  end

  def token_missing_message?(app)
    app.speaker.messages.any? do |m|
      m.is_a?(String) && m.include?('No stored Trakt token found')
    end
  end

  class FakeDb
    def initialize(rows)
      @rows = rows
    end

    def get_rows(_table, _conditions = {})
      @rows
    end
  end
end
