class Logger
  def self.renew_logs(log_dir)
    FileUtils.mv(log_dir + '/medialibrarian.log', log_dir + "/medialibrarian.log.old.#{DateTime.now.strftime('%Y.%m.%d_%H.%M.%S')}") if File.exist?(log_dir + '/medialibrarian.log')
    FileUtils.mv(log_dir + '/medialibrarian_errors.log', log_dir + "/medialibrarian_errors.log.old.#{DateTime.now.strftime('%Y.%m.%d_%H.%M.%S')}") if File.exist?(log_dir + '/medialibrarian_errors.log')
    $speaker = SimpleSpeaker::Speaker.new(log_dir + '/medialibrarian.log', log_dir + '/medialibrarian_errors.log')
  end
end