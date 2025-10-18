module Services
  class MediaBoxSyncService
    def self.sync(**options)
      new.sync(**options)
    end

    def initialize(speaker: $speaker)
      @speaker = speaker
    end

    def sync(local_folder:, remote_user:, remote_server:, remote_folder:, clean_remote_folder: [], bandwith_limit: 0, active_hours: {}, ssh_opts: {}, exclude_folders_in_check: [], monitor_options: {})
      loop do
        begin
          unless Utils.check_if_active(active_hours)
            sleep 30
            next
          end
          low_b = 0
          while Utils.check_if_active(active_hours) && `ps ax | grep '#{remote_user}@#{remote_server}:#{remote_folder}' | grep -v grep` == ''
            fetcher = Librarian.burst_thread do
              sync_core(local_folder, remote_user, remote_server, remote_folder, clean_remote_folder, bandwith_limit, ssh_opts, active_hours, exclude_folders_in_check)
            end
            while fetcher.alive?
              if !Utils.check_if_active(active_hours) || low_b > 60
                speaker.speak_up('Bandwidth too low, restarting the synchronisation') if low_b > 24
                `pgrep -f '#{remote_user}@#{remote_server}:#{remote_folder}' | xargs kill -15`
                low_b = 0
              end
              if monitor_options.is_a?(Hash) && monitor_options['network_card'].to_s != '' && bandwith_limit > 0
                in_speed, _ = Utils.get_traffic(monitor_options['network_card'])
                low_b = in_speed && in_speed < bandwith_limit / 4 ? low_b + 1 : 0
              end
              sleep 10
            end
            exit_status = fetcher.status
            Daemon.merge_notifications(fetcher)
            sleep 3600 unless exit_status.nil?
          end
        rescue => e
          speaker.tell_error(e, Utils.arguments_dump(binding))
          sleep 180
        end
      end
    end

    def sync_core(local_folder, remote_user, remote_server, remote_folder, clean_remote_folder = [], bandwith_limit = 0, ssh_opts = {}, active_hours = {}, exclude_folders = [])
      remote_box = "#{remote_user}@#{remote_server}:#{remote_folder}"
      rsynced_clean = false
      speaker.speak_up("Starting media synchronisation with #{remote_box} - #{Time.now.utc}", 0)
      return speaker.speak_up('Would run synchonisation') if Env.pretend?
      base_opts = ['--verbose', '--recursive', '--acls', '--times', '--remove-source-files', '--human-readable', "--bwlimit=#{bandwith_limit}"]
      opts = base_opts + ["--partial-dir=#{local_folder}/.rsync-partial"]
      speaker.speak_up("Running the command: rsync #{opts.join(' ')} #{remote_box}/ #{local_folder}") if Env.debug?
      Rsync.run("#{remote_box}/", "#{local_folder}", opts, ssh_opts['port'] || 22, ssh_opts['keys']) do |result|
        result.changes.each do |change|
          speaker.speak_up "#{change.filename} (#{change.summary})"
        end
        if result.success?
          rsynced_clean = true
        else
          speaker.speak_up result.error
        end
      end
      clean_remote(remote_server, remote_user, ssh_opts, clean_remote_folder) if rsynced_clean && clean_remote_folder.is_a?(Array)
      unless rsynced_clean || Utils.check_if_active(active_hours)
        Services::RemoteComparisonService.compare(path: local_folder, remote_server: remote_server, remote_user: remote_user, filter_criteria: { 'days_newer' => 10, 'exclude_path' => exclude_folders }, ssh_opts: ssh_opts, no_prompt: 1)
      end
      speaker.speak_up("Finished media box synchronisation - #{Time.now.utc}", 0)
      raise 'Rsync failure' unless rsynced_clean
    end

    private

    attr_reader :speaker

    def clean_remote(remote_server, remote_user, ssh_opts, clean_remote_folder)
      clean_remote_folder.each do |c|
        speaker.speak_up("Cleaning folder #{c} on #{remote_server}", 0) if Env.debug?
        Net::SSH.start(remote_server, remote_user, Utils.recursive_typify_keys(ssh_opts)) do |ssh|
          ssh.exec!('find ' + c.to_s + ' -type d -empty -exec rmdir "{}" \\;')
        end
      end
    end
  end
end
