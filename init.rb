APP_NAME = 'librarian'
$env_flags = {
    :debug => 0,
    :no_email_notif => 0,
    :pretend => 0,
    :expiration_period => 0
}
$config_dir = Dir.home + '/.medialibrarian'
$config_file = $config_dir + '/conf.yml'
$config_example = File.dirname(__FILE__) + '/config/conf.yml.example'
$temp_dir = $config_dir + '/tmp'
log_dir = $config_dir + '/log'
$template_dir = $config_dir + '/templates'
$tracker_dir = $config_dir + '/trackers'
$pid_dir = $config_dir + '/pids'
$pidfile = $pid_dir + '/pid.file'
#Create default folders if doesn't exist
FileUtils.mkdir($config_dir) unless File.exist?($config_dir)
FileUtils.mkdir($temp_dir) unless File.exist?($temp_dir)
FileUtils.mkdir($pid_dir) unless File.exist?($pid_dir)
unless File.exist?($template_dir)
  FileUtils.cp_r File.dirname(__FILE__) + '/config/templates/', $template_dir
end
#Logger
FileUtils.mkdir($config_dir + '/log') unless File.exist?($config_dir + '/log')
$speaker = SimpleSpeaker::Speaker.new
$args_dispatch = SimpleArgsDispatch::Agent.new($speaker, $env_flags)
#Load app and settings
Dir[File.dirname(__FILE__) + '/app/services/*.rb'].sort.each { |file| require file }
Dir[File.dirname(__FILE__) + '/app/*.rb'].each { |file| require file }
$config = SimpleConfigMan.load_settings($config_dir, $config_file, $config_example)
#Daemon options
$api_option = {
    'bind_address' => '127.0.0.1',
    'listen_port' => '8888'
}
$workers_pool_size = $config['daemon'] ? $config['daemon']['workers_pool_size'] || 4 : 4
$queue_slots = $config['daemon'] ? $config['daemon']['queue_slots'] || 4 : 4
$daemon_client = nil