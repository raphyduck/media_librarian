class MkvMuxer
  attr_reader :command

  def initialize(path, output = nil, force = false)
    path = path.gsub('\\', '/')

    @command = ''
    @mkv = Dir[File.join(path, '*.mkv')].first rescue nil
    @ass = Dir[File.join(path, '*.ass')].first rescue nil
    @files = File.directory?(path) ? nil : path
    @chapters = Dir[File.join(path, '*.xml')].first rescue nil
    @output = output || "#{@mkv}_"

    @fonts = [].tap { |fonts|
      %w(ttf ttc otf).each { |format| fonts << Dir[File.join(path, 'font*', "*.#{format}")] }
    }.flatten.compact.uniq

    raise Exception, 'No mkv or ass found' if (!@mkv || !@ass) && !@files
    raise Exception, 'Target mkv already exists' if !force && File.exists?(@output)
  end

  def prepare(language = '', fonts = true, chapters = true)
    options = []
    options << {opt: '-o', val: @output}
    #options << {opt: '--default-track', val: '0'}
    options << {opt: '--track-name', val: "0:#{language}"} if language.to_s != ''
    options << {opt: '--language', val: "0:#{language[0..2].downcase}"} if language.to_s != ''
    options << {opt: '--no-chapters --chapters', val: chapters} if @chapters

    @fonts.each { |font|
      options << {opt: '--attachment-mime-type', val: 'application/x-truetype-font'}
      options << {opt: '--attach-file', val: font}
    } if fonts

    options << {val: @ass}
    options << {val: @mkv}
    options << {val: @files}

    @command = [].tap { |cmd|
      options.each { |option|
        cmd << option[:opt] if option[:opt]
        cmd << option[:val] if option[:val]
      }
    }
  end

  def merge!(mkvmerge = '/usr/bin/mkvmerge')
    $speaker.speak_up "Will run the following command: '#{mkvmerge} #{@command}'" if Env.debug?
    Open3.popen3(mkvmerge, *@command) do |stdin, stdout, stderr, wait_thr|
      exit_code = wait_thr.value

      if exit_code != 0
        err = stderr.read.chomp
        err = stdout.read.chomp if err.strip.empty?
        raise Exception, err
      end
    end
  end

  def apply_crc32!
    crc32 = MkvMuxer.crc32_of @output
    FileUtils.move(@output, @output.gsub(/CRC32/, crc32)[0..-2])
  end

  class << self
    def crc32_of(file)
      File.open(file, 'rb') { |f| Zlib.crc32 f.read }.to_s(16)
    end
  end
end