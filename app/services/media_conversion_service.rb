module Services
  class MediaConversionService
    def self.convert(**options)
      new.convert(**options)
    end

    def initialize(speaker: $speaker)
      @speaker = speaker
    end

    def convert(path:, input_format:, output_format:, no_warning: 0, rename_original: 1, move_destination: '', search_pattern: '', qualities: nil)
      name = ''
      results = []
      type = EXTENSIONS_TYPE.find { |_, v| v.include?(input_format) }&.first
      return speaker.speak_up('Unknown input format') unless type
      unless VALID_CONVERSION_INPUTS[type]&.include?(input_format)
        return speaker.speak_up("Invalid input format, needs to be one of #{VALID_CONVERSION_INPUTS[type]}")
      end
      unless VALID_CONVERSION_OUTPUT[type]&.include?(output_format)
        return speaker.speak_up("Invalid output format, needs to be one of #{VALID_CONVERSION_OUTPUT[type]}")
      end
      if no_warning.to_i.zero? && input_format == 'pdf'
        continue = speaker.ask_if_needed('WARNING: The images extractor is incomplete, can result in corrupted or incomplete CBZ file. Do you want to continue? (y/n)')
        return unless continue == 'y'
      end
      return speaker.speak_up("#{path} does not exist!") unless File.exist?(path)
      if FileTest.directory?(path)
        FileUtils.search_folder(path, { 'regex' => ".*#{search_pattern.to_s + '.*' if search_pattern.to_s != ''}\\.#{input_format}" }).each do |f|
          results += convert(path: f[0], input_format: input_format, output_format: output_format, no_warning: 1, rename_original: rename_original, move_destination: move_destination)
        end
      elsif search_pattern.to_s != ''
        speaker.speak_up 'Can not use search_pattern if path is not a directory'
      else
        input_format = FileUtils.get_extension(path)
        Dir.chdir(File.dirname(path)) do
          move_destination = Dir.pwd if move_destination.to_s == ''
          name = File.basename(path).gsub(/(.*)\.[\w\d]{1,4}/, '\\1')
          dest_file = "#{move_destination}/#{name.gsub(/^_?/, '')}.#{output_format}"
          final_file = dest_file
          if File.exist?(File.basename(dest_file))
            if input_format == output_format
              dest_file = "#{move_destination}/#{name.gsub(/^_?/, '')}.proper.#{output_format}"
            else
              return results
            end
          end
          speaker.speak_up("Will convert #{name} to #{output_format.to_s.upcase} format #{dest_file}")
          FileUtils.mkdir(File.dirname(name)) unless File.directory?(File.dirname(name))
          skipping =
            case type
            when :books
              Book.convert_comics(path, name, input_format, output_format, dest_file, no_warning)
            when :music
              Music.convert_songs(path, dest_file, input_format, output_format, qualities)
            when :video
              VideoUtils.convert_videos(path, dest_file, input_format, output_format)
            end
          return results if skipping.to_i > 0
          FileUtils.mv(File.basename(path), "_#{File.basename(path)}_") if rename_original.to_i > 0
          FileUtils.mv(dest_file, final_file) if final_file != dest_file
          speaker.speak_up("#{name} converted!")
          results << final_file
        end
      end
      results
    rescue => e
      speaker.tell_error(e, Utils.arguments_dump(binding))
      name.to_s != '' && Dir.exist?(File.dirname(path) + '/' + name) && FileUtils.rm_r(File.dirname(path) + '/' + name)
      raise e
    end

    private

    attr_reader :speaker
  end
end
