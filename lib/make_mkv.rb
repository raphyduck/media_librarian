class MakeMkv
    attr_reader :command, :output, :makemkvcon

    def initialize(input, output = nil)
      input.gsub!('\\', '/')
      output.gsub!('\\', '/')

      @makemkvcon = 'makemkvcon'
      @input = input
      @output = output || input
      @output = File.directory?(@output) ? @output : File.dirname(@output)
      raise Exception, 'No iso file found' if !@input || !File.exist?(@input)
      @command = ['-r', "iso:#{@input}", 'all', @output]
      # makemkvcon iso:source_file all File.dirname(destination)
    end

    def iso_to_mkv!
      MediaLibrarian.app.speaker.speak_up "Will run the following command: '#{makemkvcon} #{@command}'" if Env.debug?
      return MediaLibrarian.app.speaker.speak_up "Would run the following command: '#{makemkvcon} #{@command}'" if Env.pretend?
      Open3.popen3(makemkvcon, *(['mkv'] + @command)) do |_, stdout, stderr, wait_thr|
        exit_code = wait_thr.value
        if exit_code != 0
          err = stderr.read.chomp
          err = stdout.read.chomp if err.strip.empty?
          raise Exception, err
        end
      end
    end
end