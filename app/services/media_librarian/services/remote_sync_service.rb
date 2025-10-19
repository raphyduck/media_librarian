# frozen_string_literal: true

module MediaLibrarian
  module Services
    class RemoteComparisonRequest
      attr_reader :path, :remote_server, :remote_user, :filter_criteria,
                  :ssh_opts, :no_prompt

      def initialize(path:, remote_server:, remote_user:, filter_criteria: {},
                     ssh_opts: {}, no_prompt: 0)
        @path = path
        @remote_server = remote_server
        @remote_user = remote_user
        @filter_criteria = filter_criteria
        @ssh_opts = ssh_opts
        @no_prompt = no_prompt
      end
    end

    class RemoteFetchRequest
      attr_reader :local_folder, :remote_user, :remote_server, :remote_folder,
                  :clean_remote_folder, :bandwidth_limit, :ssh_opts,
                  :active_hours, :exclude_folders_in_check, :monitor_options

      def initialize(local_folder:, remote_user:, remote_server:, remote_folder:,
                     clean_remote_folder: [], bandwith_limit: 0, ssh_opts: {},
                     active_hours: {}, exclude_folders_in_check: [],
                     monitor_options: {})
        @local_folder = local_folder
        @remote_user = remote_user
        @remote_server = remote_server
        @remote_folder = remote_folder
        @clean_remote_folder = clean_remote_folder
        @bandwidth_limit = bandwith_limit
        @ssh_opts = ssh_opts
        @active_hours = active_hours
        @exclude_folders_in_check = exclude_folders_in_check
        @monitor_options = monitor_options
      end
    end

    class RemoteSyncService < BaseService
      def compare_remote_files(request)
        speaker.speak_up("Starting cleaning remote files on #{request.remote_user}@#{request.remote_server}:#{request.path} using criteria #{request.filter_criteria}, no_prompt=#{request.no_prompt}")
        ssh_opts = Utils.recursive_typify_keys(request.ssh_opts) || {}
        tries = 10
        list = file_system.directory?(request.path) ?
               file_system.search_folder(request.path, request.filter_criteria) :
               [[request.path, '']]
        list.each do |file_entry|
          begin
            f_path = file_entry[0]
            speaker.speak_up("Comparing #{f_path} on local and remote #{request.remote_server}")
            local_md5sum = file_system.md5sum(f_path)
            remote_md5sum = fetch_remote_md5sum(request, ssh_opts, f_path)
            speaker.speak_up("Local md5sum is #{local_md5sum}")
            speaker.speak_up("Remote md5sum is #{remote_md5sum}")
            handle_comparison_result(request, f_path, local_md5sum, remote_md5sum)
          rescue StandardError => e
            speaker.tell_error(e, "RemoteSyncService.compare_remote_files - file #{file_entry[0]}")
            retry if (tries -= 1) > 0
          end
        end
      end

      def fetch_media_box(request)
        loop do
          begin
            unless Utils.check_if_active(request.active_hours)
              sleep 30
              next
            end
            fetch_once(request)
          rescue StandardError => e
            speaker.tell_error(e, Utils.arguments_dump(binding))
            sleep 180
          end
        end
      end

      def fetch_media_box_core(local_folder, remote_user, remote_server, remote_folder,
                                clean_remote_folder = [], bandwith_limit = 0,
                                ssh_opts = {}, active_hours = {}, exclude_folders = [])
        request = RemoteFetchRequest.new(
          local_folder: local_folder,
          remote_user: remote_user,
          remote_server: remote_server,
          remote_folder: remote_folder,
          clean_remote_folder: clean_remote_folder,
          bandwith_limit: bandwith_limit,
          ssh_opts: ssh_opts,
          active_hours: active_hours,
          exclude_folders_in_check: exclude_folders
        )
        fetch_once(request)
      end

      private

      def fetch_once(request)
        remote_box = "#{request.remote_user}@#{request.remote_server}:#{request.remote_folder}"
        rsynced_clean = false
        speaker.speak_up("Starting media synchronisation with #{remote_box} - #{Time.now.utc}", 0)
        return speaker.speak_up('Would run synchonisation') if Env.pretend?

        base_opts = ['--verbose', '--recursive', '--acls', '--times', '--remove-source-files', '--human-readable', "--bwlimit=#{request.bandwidth_limit}"]
        opts = base_opts + ["--partial-dir=#{request.local_folder}/.rsync-partial"]
        speaker.speak_up("Running the command: rsync #{opts.join(' ')} #{remote_box}/ #{request.local_folder}") if Env.debug?
        Rsync.run("#{remote_box}/", request.local_folder, opts, request.ssh_opts['port'] || 22, request.ssh_opts['keys']) do |result|
          result.changes.each do |change|
            speaker.speak_up "#{change.filename} (#{change.summary})"
          end
          if result.success?
            rsynced_clean = true
          else
            speaker.speak_up result.error
          end
        end
        clean_remote_directories(request) if rsynced_clean
        ensure_local_remote_consistency(request, rsynced_clean)
        speaker.speak_up("Finished media box synchronisation - #{Time.now.utc}", 0)
        raise 'Rsync failure' unless rsynced_clean
      end

      def clean_remote_directories(request)
        return unless request.clean_remote_folder.is_a?(Array)

        request.clean_remote_folder.each do |folder|
          speaker.speak_up("Cleaning folder #{folder} on #{request.remote_server}", 0) if Env.debug?
          Net::SSH.start(request.remote_server, request.remote_user, Utils.recursive_typify_keys(request.ssh_opts)) do |ssh|
            ssh.exec!('find ' + folder.to_s + ' -type d -empty -exec rmdir "{}" \;')
          end
        end
      end

      def ensure_local_remote_consistency(request, rsynced_clean)
        return if rsynced_clean || Utils.check_if_active(request.active_hours)

        comparison_request = RemoteComparisonRequest.new(
          path: request.local_folder,
          remote_server: request.remote_server,
          remote_user: request.remote_user,
          filter_criteria: { 'days_newer' => 10, 'exclude_path' => request.exclude_folders_in_check },
          ssh_opts: request.ssh_opts,
          no_prompt: 1
        )
        compare_remote_files(comparison_request)
      end

      def fetch_remote_md5sum(request, ssh_opts, path)
        remote_md5sum = ''
        Net::SSH.start(request.remote_server, request.remote_user, ssh_opts) do |ssh|
          remote_md5sum = []
          ssh.exec!("md5sum \"#{path}\"") do |_, stream, data|
            remote_md5sum << data if stream == :stdout
          end
          remote_md5sum = remote_md5sum.first
          remote_md5sum = remote_md5sum ? remote_md5sum.gsub(/(\w*)( .*\n)/, '\\1') : ''
        end
        remote_md5sum
      end

      def handle_comparison_result(request, path, local_md5sum, remote_md5sum)
        if local_md5sum != remote_md5sum || local_md5sum.to_s == '' || remote_md5sum.to_s == ''
          speaker.speak_up('Mismatch between the 2 files, the remote file might not exist or the local file is incorrectly downloaded')
          delete_local = speaker.ask_if_needed('Delete the local file? (y/n)', request.no_prompt, 'n') == 'y'
          file_system.rm_r(path) if delete_local && local_md5sum.to_s != '' && remote_md5sum.to_s != ''
        else
          speaker.speak_up('The 2 files are identical!')
          delete_remote = speaker.ask_if_needed('Delete the remote file? (y/n)', request.no_prompt, 'y') == 'y'
          if delete_remote
            Net::SSH.start(request.remote_server, request.remote_user, Utils.recursive_typify_keys(request.ssh_opts)) do |ssh|
              ssh.exec!("rm \"#{path}\"")
            end
          end
        end
      end
    end
  end
end
