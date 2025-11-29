# frozen_string_literal: true

require 'rbconfig'
require File.join(RbConfig::CONFIG.fetch('rubylibdir'), 'logger')

class Logger
  def self.log_paths(log_dir)
    [
      File.join(log_dir, 'medialibrarian.log'),
      File.join(log_dir, 'medialibrarian_errors.log')
    ]
  end

  def self.renew_logs(log_dir)
    log_path, error_log_path = log_paths(log_dir)
    FileUtils.mv(log_path, "#{log_path}.old.#{DateTime.now.strftime('%Y.%m.%d_%H.%M.%S')}") if File.exist?(log_path)
    FileUtils.mv(error_log_path, "#{error_log_path}.old.#{DateTime.now.strftime('%Y.%m.%d_%H.%M.%S')}") if File.exist?(error_log_path)
    MediaLibrarian.app.speaker = SimpleSpeaker::Speaker.new(log_path, error_log_path)
  end
end