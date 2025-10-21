# frozen_string_literal: true

module MediaLibrarian
  module Services
    class MediaConversionRequest
      attr_reader :path, :input_format, :output_format, :no_warning,
                  :rename_original, :move_destination, :search_pattern,
                  :qualities

      def initialize(path:, input_format:, output_format:, no_warning: 0,
                     rename_original: 1, move_destination: '', search_pattern: '',
                     qualities: nil)
        @path = path
        @input_format = input_format
        @output_format = output_format
        @no_warning = no_warning
        @rename_original = rename_original
        @move_destination = move_destination
        @search_pattern = search_pattern
        @qualities = qualities
      end
    end

    class MediaConversionService < BaseService
      def convert(request)
        last_name = ''
        results = []
        missing_path = false
        unless file_system.exist?(request.path)
          speaker.speak_up("#{request.path} does not exist!")
          missing_path = true
        end

        type_pair = EXTENSIONS_TYPE.find { |_type, values| values.include?(request.input_format) }
        return speaker.speak_up('Unknown input format') unless type_pair

        type = type_pair.first
        unless VALID_CONVERSION_INPUTS[type]&.include?(request.input_format)
          return speaker.speak_up("Invalid input format, needs to be one of #{VALID_CONVERSION_INPUTS[type]}")
        end
        unless VALID_CONVERSION_OUTPUT[type]&.include?(request.output_format)
          return speaker.speak_up("Invalid output format, needs to be one of #{VALID_CONVERSION_OUTPUT[type]}")
        end

        if request.no_warning.to_i.zero? && request.input_format == 'pdf'
          continue = speaker.ask_if_needed(
            'WARNING: The images extractor is incomplete, can result in corrupted or incomplete CBZ file. Do you want to continue? (y/n)'
          )
          return unless continue == 'y'
        end

        return [] if missing_path

        if file_system.directory?(request.path)
          directory_results, last_name = convert_directory(request)
          results += directory_results
        elsif request.search_pattern.to_s != ''
          speaker.speak_up 'Can not use search_pattern if path is not a directory'
        else
          file_results, last_name = convert_file(request, type)
          results += file_results
        end
        results
      rescue StandardError => e
        speaker.tell_error(e, Utils.arguments_dump(binding))
        cleanup_failed_conversion(last_name, request)
        raise e
      end

      private

      def convert_directory(request)
        directory_results = []
        last_name = ''
        criteria = {
          'regex' => ".*#{request.search_pattern.to_s + '.*' if request.search_pattern.to_s != ''}\\.#{request.input_format}"
        }
        file_system.search_folder(request.path, criteria).each do |file|
          nested_request = MediaConversionRequest.new(
            path: file[0],
            input_format: request.input_format,
            output_format: request.output_format,
            no_warning: 1,
            rename_original: request.rename_original,
            move_destination: request.move_destination,
            search_pattern: '',
            qualities: request.qualities
          )
          nested_results = convert(nested_request)
          directory_results += nested_results
          last_name = File.basename(file[0]).gsub(/(.*)\.[\w\d]{1,4}/, '\\1') if nested_results.any?
        end
        [directory_results, last_name]
      end

      def convert_file(request, type)
        name = ''
        results = []
        file_system.chdir(File.dirname(request.path)) do
          destination = request.move_destination.to_s == '' ? Dir.pwd : request.move_destination
          name = File.basename(request.path).gsub(/(.*)\.[\w\d]{1,4}/, '\\1')
          dest_file = File.join(destination, "#{name.gsub(/^_?/, '')}.#{request.output_format}")
          final_file = dest_file

          if File.exist?(File.basename(dest_file))
            if request.input_format == request.output_format
              dest_file = File.join(destination, "#{name.gsub(/^_?/, '')}.proper.#{request.output_format}")
            else
              return results
            end
          end

          speaker.speak_up("Will convert #{name} to #{request.output_format.to_s.upcase} format #{dest_file}")
          ensure_destination_directory(name)

          skipping = if type == :video
                       VideoUtils.convert_videos(request.path, dest_file, request.input_format, request.output_format)
                     else
                       speaker.speak_up("Unsupported media type: #{type}")
                       1
                     end
          return [results, name] if skipping.to_i.positive?

          handle_original_file(request, dest_file, final_file)
          speaker.speak_up("#{name} converted!")
          results << final_file
        end
        [results, name]
      end

      def ensure_destination_directory(name)
        dir = File.dirname(name)
        return if dir == '.'

        file_system.mkdir(dir) unless File.directory?(dir)
      end

      def handle_original_file(request, dest_file, final_file)
        if request.rename_original.to_i.positive?
          file_system.mv(File.basename(request.path), "_#{File.basename(request.path)}_")
        end
        file_system.mv(dest_file, final_file) if final_file != dest_file
      end

      def cleanup_failed_conversion(name, request)
        return if name.to_s == ''

        dir = File.dirname(request.path) + '/' + name
        file_system.rm_r(dir) if Dir.exist?(dir)
      end
    end
  end
end
