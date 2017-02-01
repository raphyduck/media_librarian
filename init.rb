#Set global variables
$config_dir = Dir.home + '/.medialibrarian'
$config_file = $config_dir + '/conf.yml'
$temp_dir = $config_dir + '/tmp'
$log_dir = $config_dir + '/log'
$deluge_connected = nil
$deluge_options = {}
$deluge_torrents_added = []
$pending_magnet_links = {}
#Some constants
NEW_LINE = "\n"
#Create default folders if doesn't exist
Dir.mkdir($config_dir) unless File.exist?($config_dir)
Dir.mkdir($log_dir) unless File.exist?($log_dir)
Dir.mkdir($temp_dir) unless File.exist?($temp_dir)
$logger = Logger.new($log_dir + '/medialibrarian.log')
$logger_error = Logger.new($log_dir + '/medialibrarian_errors.log')
#Load app and settings
Dir[File.dirname(__FILE__) + '/app/*.rb'].each { |file| require file }
Config.load_settings

#Start torrent_client
$t_client = TorrentClient.new

#Start trakt client
if $config['trakt']
  $trakt_account = $config['trakt']['account_id']
  $trakt = Trakt.new({
                         :client_id => $config['trakt']['client_id'],
                         :client_secret => $config['trakt']['client_secret'],
                         :account_id => $config['trakt']['account_id']
                     })
end

#Set up and open app DB
db_path=$config_dir +"/librarian.db"
$db = Storage::Db.new(db_path)

#start Kodi client
if $config['kodi']
  Xbmc.base_uri $config['kodi']['host']
  Xbmc.basic_auth $config['kodi']['username'], $config['kodi']['password']
  Xbmc.load_api! # This will call JSONRPC.Introspect and create all subclasses and methods dynamically
end