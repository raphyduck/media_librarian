module Services
  class RemoteComparisonService
    def self.compare(**options)
      new.compare(**options)
    end

    def initialize(speaker: $speaker)
      @speaker = speaker
    end

    def compare(path:, remote_server:, remote_user:, filter_criteria: {}, ssh_opts: {}, no_prompt: 0)
      speaker.speak_up("Starting cleaning remote files on #{remote_user}@#{remote_server}:#{path} using criteria #{filter_criteria}, no_prompt=#{no_prompt}")
      ssh_opts = Utils.recursive_typify_keys(ssh_opts) || {}
      tries = 10
      list = FileTest.directory?(path) ? FileUtils.search_folder(path, filter_criteria) : [[path, '']]
      list.each do |f|
        begin
          f_path = f[0]
          speaker.speak_up("Comparing #{f_path} on local and remote #{remote_server}")
          local_md5sum = FileUtils.md5sum(f_path)
          remote_md5sum = fetch_remote_md5(remote_server, remote_user, ssh_opts, f_path)
          speaker.speak_up("Local md5sum is #{local_md5sum}")
          speaker.speak_up("Remote md5sum is #{remote_md5sum}")
          handle_comparison_result(f_path, local_md5sum, remote_md5sum, remote_server, remote_user, ssh_opts, no_prompt)
        rescue => e
          speaker.tell_error(e, "Library.compare_remote_files - file #{f[0]}")
          retry if (tries -= 1) > 0
        end
      end
    end

    private

    attr_reader :speaker

    def fetch_remote_md5(remote_server, remote_user, ssh_opts, f_path)
      remote_md5sum = ''
      Net::SSH.start(remote_server, remote_user, ssh_opts) do |ssh|
        remote_md5sum = []
        ssh.exec!("md5sum \"#{f_path}\"") do |_, stream, data|
          remote_md5sum << data if stream == :stdout
        end
        remote_md5sum = remote_md5sum.first
        remote_md5sum = remote_md5sum ? remote_md5sum.gsub(/(\w*)( .*\n)/, '\\1') : ''
      end
      remote_md5sum
    end

    def handle_comparison_result(f_path, local_md5sum, remote_md5sum, remote_server, remote_user, ssh_opts, no_prompt)
      if local_md5sum != remote_md5sum || local_md5sum.to_s.empty? || remote_md5sum.to_s.empty?
        speaker.speak_up('Mismatch between the 2 files, the remote file might not exist or the local file is incorrectly downloaded')
        if local_md5sum.to_s != '' && remote_md5sum.to_s != '' && speaker.ask_if_needed('Delete the local file? (y/n)', no_prompt, 'n') == 'y'
          FileUtils.rm_r(f_path)
        end
      else
        speaker.speak_up('The 2 files are identical!')
        if speaker.ask_if_needed('Delete the remote file? (y/n)', no_prompt, 'y') == 'y'
          Net::SSH.start(remote_server, remote_user, ssh_opts) do |ssh|
            ssh.exec!("rm \"#{f_path}\"")
          end
        end
      end
    end
  end
end
