#Set global variables
config_dir = Dir.home + '/.medialibrarian'
$config_file = config_dir + '/conf.yml'
$config_example = File.dirname(__FILE__) + '/config/conf.yml.example'
$temp_dir = config_dir + '/tmp'
log_dir = config_dir + '/log'
$template_dir = config_dir + '/templates'
$move_completed_torrent = nil
$deluge_connected = nil
$deluge_options = {}
$deluge_torrents_added = []
$deluge_torrents_preadded = []
$pending_magnet_links = {}
$processed_torrent_id = {}
$cleanup_trakt_list = []
$dir_to_delete = []
$dowloaded_links = []
#Some constants
NEW_LINE = "\n"
LINE_SEPARATOR = '---------------------------------------------------------'
RESOLUTIONS = %w(2160p 1080p 1080i 720p 720i hr 576p 480p 368p 360p)
SOURCES = %w(bluray remux dvdrip webdl hdtv webrip bdscr dvdscr sdtv dsr tvrip preair ppvrip hdrip r5 cam workprint)
CODECS = %w(10bit h265 h264 xvid divx)
AUDIO = %w(truehd dts dtshd flac dd+5.1 ac3 dd5.1 aac mp3)
VALID_QUALITIES = RESOLUTIONS + SOURCES + CODECS + AUDIO + %w(multi)
FILENAME_NAMING_TEMPLATE=%w(
    movies_name
    series_name
    episode_season
    episode_numbering
    episode_name
    quality
    proper
)
REGEX_QUALITIES=Regexp.new('[ \.\(\)\-](' + VALID_QUALITIES.join('|') + ')')
VALID_VIDEO_EXT='.*\.(mkv|avi|mp4|mpg)'
PRIVATE_TRACKERS = [{:name => 'yggtorrent', :url => 'https://yggtorrent.com'},
                    {:name => 'wop', :url => 'https://worldofp2p.net'},
                    {:name => 'torrentleech', :url => 'https://www.torrentleech.org'}]
TORRENT_TRACKERS = PRIVATE_TRACKERS + [{:name => 'thepiratebay', :url => 'https://thepiratebay.se'}]

#Create default folders if doesn't exist
Dir.mkdir(config_dir) unless File.exist?(config_dir)
Dir.mkdir(log_dir) unless File.exist?(log_dir)
Dir.mkdir($temp_dir) unless File.exist?($temp_dir)
unless File.exist?($template_dir)
  FileUtils.cp_r File.dirname(__FILE__) + '/config/templates/', $template_dir
end
$speaker = SimpleSpeaker::Speaker.new(log_dir + '/medialibrarian.log', log_dir + '/medialibrarian_errors.log')
#Load app and settings
Dir[File.dirname(__FILE__) + '/app/*.rb'].each { |file| require file }
$config = SimpleConfigMan.load_settings(config_dir, $config_file, $config_example)

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

#Start thetvdb client
$tvdb = $config['tvdb'] && $config['tvdb']['api_key'] ? TvdbParty::Search.new($config['tvdb']['api_key']) : nil

#Set up and open app DB
db_path=config_dir +"/librarian.db"
$db = Storage::Db.new(db_path)

#start Kodi client
if $config['kodi']
  Xbmc.base_uri $config['kodi']['host']
  Xbmc.basic_auth $config['kodi']['username'], $config['kodi']['password']
  Xbmc.load_api! rescue nil # This will call JSONRPC.Introspect and create all subclasses and methods dynamically
end

#Configure email alerts
$email_templates = File.dirname(__FILE__) + '/app/mailer_templates'
Dir.mkdir($mail_templates) unless File.exist?($email_templates)
$email = $config['email']
if $email
  Hanami::Mailer.configure do
    root $email_templates
    delivery_method :smtp,
                    address:              $email['host'],
                    port:                 $email['port'],
                    domain:               $email['domain'],
                    user_name:            $email['username'],
                    password:             $email['password'],
                    authentication:       $email['auth_type'],
                    enable_starttls_auto: true
  end.load!
end
$email_msg = $email ? '' : nil

#String comparator
$str_closeness = FuzzyStringMatch::JaroWinkler.create( :pure )