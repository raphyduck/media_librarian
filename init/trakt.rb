require_relative '../boot/librarian'
require_relative 'db'

app = MediaLibrarian::Boot.application

if app.config['trakt']
  app.trakt_account = app.config['trakt']['account_id']
  token_rows = app.db.get_rows('trakt_auth', { account: app.trakt_account })
  token_row = token_rows.empty? ? nil : Utils.recursive_typify_keys(token_rows.first.reject { |k, _| k.to_s == :account.to_s }, 0)
  token_row = nil if token_row.nil? || token_row.values.any? { |v| v.to_s == '' || v.to_s == '0' }
  app.trakt = Trakt.new({
                          client_id: app.config['trakt']['client_id'],
                          client_secret: app.config['trakt']['client_secret'],
                          account_id: app.trakt_account,
                          speaker: app.speaker,
                          token: token_row
                        })
  TraktAgent.get_trakt_token
end
