APP_NAME='librarian'
$env_flags = {
    'debug' => 0,
    'no_email_notif' => 0,
    'pretend' => 0
}
config_dir = Dir.home + '/.medialibrarian'
$config_file = config_dir + '/conf.yml'
$config_example = File.dirname(__FILE__) + '/config/conf.yml.example'
$temp_dir = config_dir + '/tmp'
log_dir = config_dir + '/log'
$template_dir = config_dir + '/templates'
$pid_dir = config_dir + '/pids'
$pidfile = $pid_dir + '/pid.file'
#Create default folders if doesn't exist
Utils.file_mkdir(config_dir) unless File.exist?(config_dir)
Utils.file_mkdir(log_dir) unless File.exist?(log_dir)
Utils.file_mkdir($temp_dir) unless File.exist?($temp_dir)
Utils.file_mkdir($pid_dir) unless File.exist?($pid_dir)
unless File.exist?($template_dir)
  FileUtils.cp_r File.dirname(__FILE__) + '/config/templates/', $template_dir
end
#Logger
$speaker = SimpleSpeaker::Speaker.new(log_dir + '/medialibrarian.log', log_dir + '/medialibrarian_errors.log')
$args_dispatch = SimpleArgsDispatch::Agent.new($speaker, $env_flags.map{|k,_| k})
#Load app and settings
Dir[File.dirname(__FILE__) + '/app/*.rb'].each { |file| require file }
$config = SimpleConfigMan.load_settings(config_dir, $config_file, $config_example)
#Set up and open app DB
db_path=config_dir +"/librarian.db"
$db = Storage::Db.new(db_path)
#String comparator
$str_closeness = FuzzyStringMatch::JaroWinkler.create( :pure )