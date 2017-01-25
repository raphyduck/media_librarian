#Set global variables
$config_dir = Dir.home + '/.medialibrarian'
$config_file = $config_dir + '/conf.yml'
$temp_dir = $config_dir + '/tmp'
$log_dir = $config_dir + '/log'
$deluge_connected = nil
#Create default folders if doesn't exist
Dir.mkdir($config_dir) unless File.exist?($config_dir)
Dir.mkdir($log_dir) unless File.exist?($log_dir)
Dir.mkdir($temp_dir) unless File.exist?($temp_dir)
#Load app and settings
Dir[File.dirname(__FILE__) + '/app/*.rb'].each {|file| require file }
Config.load_settings

#Start torrent_client
$t_client = TorrentClient.new