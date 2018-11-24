require File.dirname(__FILE__) + '/db'
#Start trakt client
if $config['trakt']
  $trakt_account = $config['trakt']['account_id']
  token_rows = $db.get_rows('trakt_auth', {:account => $trakt_account})
  token_row = token_rows.empty? ? nil : Utils.recursive_typify_keys(token_rows.first.select {|k, _| k.to_s != :account}, 0)
  token_row = nil if token_row.nil? || token_row.values.any? {|v| v.to_s == '' || v.to_s == '0'}
  $trakt = Trakt.new({
                         :client_id => $config['trakt']['client_id'],
                         :client_secret => $config['trakt']['client_secret'],
                         :account_id => $trakt_account,
                         :speaker => $speaker,
                         :token => token_row
                     })
  #Refresh token if necessary #TODO: Fix me
  token = $trakt.access_token
  $db.insert_row('trakt_auth', token.merge({:account => $trakt_account}), 1) if token
end