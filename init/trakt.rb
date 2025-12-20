# frozen_string_literal: true

require 'trakt'

require_relative '../boot/librarian'
require_relative 'db'
require_relative '../lib/http_debug_logger'

app = MediaLibrarian::Boot.application
trakt_config = app.config['trakt']

if trakt_config.is_a?(Hash)
  account_id = trakt_config['account_id'].to_s.strip
  client_id = trakt_config['client_id'].to_s.strip
  client_secret = trakt_config['client_secret'].to_s.strip

  credentials = { account_id: account_id, client_id: client_id, client_secret: client_secret }
  missing_credentials = credentials.any? do |key, value|
    value.empty? || value == key.to_s
  end

  if missing_credentials
    app.speaker.speak_up('Skipping Trakt integration because credentials are missing or still set to defaults.', 0)
  else
    app.trakt_account = account_id
    token_rows = app.db.get_rows('trakt_auth', { account: app.trakt_account })
    token_row = token_rows.empty? ? nil : Utils.recursive_typify_keys(token_rows.first.reject { |k, _| k.to_s == :account.to_s }, 0)
    token_row = nil if token_row.nil? || token_row.values.any? { |v| v.to_s == '' || v.to_s == '0' }

    app.trakt = Trakt.new({
                            client_id: client_id,
                            client_secret: client_secret,
                            account_id: app.trakt_account,
                            speaker: app.speaker,
                            token: token_row
                          })

    begin
      app.trakt.account.access_token
      token = app.trakt.token
      app.db.insert_row('trakt_auth', token.merge({ account: app.trakt_account }), 1) if token
    rescue StandardError => e
      app.speaker.tell_error(e, 'Trakt token initialization')
    end
  end
else
  app.speaker.speak_up('Skipping Trakt integration because no configuration is available.', 0)
end
