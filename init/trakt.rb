#Start trakt client
$cleanup_trakt_list = []
if $config['trakt']
  $trakt_account = $config['trakt']['account_id']
  $trakt = Trakt.new({
                         :client_id => $config['trakt']['client_id'],
                         :client_secret => $config['trakt']['client_secret'],
                         :account_id => $config['trakt']['account_id']
                     })
end