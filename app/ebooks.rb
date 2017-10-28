class Ebooks

  def self.compress_comics(path:, destination: '', output_format: 'cbz', remove_original: 1, skip_compress: 0)
    destination = path.gsub(/\/$/, '') + '.' + output_format if destination.to_s == ''
    case output_format
      when 'cbz'
        Utils.compress_archive(path, destination) if skip_compress.to_i == 0
      else
        $speaker.speak_up('Nothing to do, skipping')
        skip_compress = 1
    end
    Utils.file_rm_r(path) if remove_original.to_i > 0
    $speaker.speak_up("Folder #{File.basename(path)} compressed to #{output_format} comic")
    return skip_compress
  rescue => e
    $speaker.tell_error(e, "Library.compress_comics")
  end

  def self.convert_comics(path:, input_format:, output_format:, no_warning: 0, rename_original: 1, move_destination: '')
    name = ''
    valid_inputs = ['cbz', 'pdf', 'cbr']
    valid_outputs = ['cbz']
    return $speaker.speak_up("Invalid input format, needs to be one of #{valid_inputs}") unless valid_inputs.include?(input_format)
    return $speaker.speak_up("Invalid output format, needs to be one of #{valid_outputs}") unless valid_outputs.include?(output_format)
    return if no_warning.to_i == 0 && input_format == 'pdf' && $speaker.ask_if_needed("WARNING: The images extractor is incomplete, can result in corrupted or incomplete CBZ file. Do you want to continue? (y/n)") != 'y'
    return $speaker.speak_up("#{path.to_s} does not exist!") unless File.exist?(path)
    if FileTest.directory?(path)
      Utils.search_folder(path, {'regex' => ".*\.#{input_format}"}).each do |f|
        convert_comics(path: f[0], input_format: input_format, output_format: output_format, no_warning: 1, rename_original: rename_original, move_destination: move_destination)
      end
    else
      skipping = 0
      Dir.chdir(File.dirname(path)) do
        name = File.basename(path).gsub(/(.*)\.[\w]{1,4}/, '\1')
        dest_file = "#{move_destination}/#{name.gsub(/^_?/, '')}.#{output_format}"
        return if File.exist?(dest_file)
        $speaker.speak_up("Will convert #{name} to #{output_format.to_s.upcase} format #{dest_file}")
        Utils.file_mkdir(name) unless File.exist?(name)
        Dir.chdir(name) do
          case input_format
            when 'pdf'
              extractor = ExtractImages::Extractor.new
              extracted = 0
              PDF::Reader.open('../' +File.basename(path)) do |reader|
                reader.pages.each do |page|
                  extracted = extractor.page(page)
                end
              end
              unless extracted > 0
                $speaker.ask_if_needed("WARNING: Error extracting images, skipping #{name}! Press any key to continue!", no_warning)
                skipping = 1
              end
            when 'cbr', 'cbz'
              Utils.extract_archive(input_format, '../' +File.basename(path), '.')
            else
              $speaker.speak_up('Nothing to do, skipping')
              skipping = 1
          end
        end
        skipping = compress_comics(path: name, destination: dest_file, output_format: output_format, remove_original: 1, skip_compress: skipping)
        return if skipping > 0
        Utils.file_mv(File.basename(path), "_#{File.basename(path)}_") if rename_original.to_i > 0
        $speaker.speak_up("#{name} converted!")
      end
    end
  rescue => e
    $speaker.tell_error(e, "Library.convert_comics")
    name.to_s != '' && Dir.exist?(File.dirname(path) + '/' + name) && Utils.file_rm_r(File.dirname(path) + '/' + name)
  end
end