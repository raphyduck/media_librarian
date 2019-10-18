require File.dirname(__FILE__) + '/global.rb'
log_dir = $config_dir + '/log'
FileUtils.rm(log_dir + '/medialibrarian.log.old') if File.exist?(log_dir + '/medialibrarian.log.old')
FileUtils.mv(log_dir + '/medialibrarian.log', log_dir + '/medialibrarian.log.old') if File.exist?(log_dir + '/medialibrarian.log')
FileUtils.rm(log_dir + '/medialibrarian_errors.log.old') if File.exist?(log_dir + '/medialibrarian_errors.log.old')
FileUtils.mv(log_dir + '/medialibrarian_errors.log', log_dir + '/medialibrarian_errors.log.old') if File.exist?(log_dir + '/medialibrarian_errors.log')
FileUtils.mkdir(log_dir) unless File.exist?(log_dir)
$speaker = SimpleSpeaker::Speaker.new(log_dir + '/medialibrarian.log', log_dir + '/medialibrarian_errors.log')