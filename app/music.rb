class Music
  CRITERIA_KEYS = %w[artist albumartist album year decade genre].freeze

  def self.convert_songs(path, dest_file, input_format, output_format = 'mp3', qualities = nil)
    destination = dest_file.sub(/(.*)\.[\w\d]{1,4}\z/, "\\1.#{output_format}")
    if input_format == 'flac' && output_format == 'mp3'
      quality_arg = qualities || ' -b320 -q0'
      flac_converter = Flac2mp3.new({ 'encoding' => quality_arg })
      flac_converter.convert(path)
      FileUtils.mv(path.sub(/\.flac\z/, '.mp3'), destination)
    end
    destination
  end

  def self.create_playlists(folder:, criteria: {}, move_untagged: '', remove_existing_playlists: 1, random: 0)
    folder = ensure_trailing_slash(folder)
    ordered_collection = {}
    song_count = 0
    library = Hash.new { |hash, key| hash[key] = [] }

    MediaLibrarian.app.speaker.speak_up("Listing all songs in #{folder}")
    files = FileUtils.search_folder(folder, { 'regex' => '.*\.[mM][pP]3' })

    files.each do |file_entry|
      song_count += 1
      song = Mp3Info.open(file_entry[0])
      f_song = {
        path: file_entry[0].sub(folder, ''),
        length: song.length,
        artist: clean_tag(song.tag.artist || song.tag2.TPE1),
        albumartist: clean_tag(song.tag2.TPE2 || song.tag.artist || song.tag2.TPE1),
        title: clean_tag(song.tag.title || song.tag2.TIT2),
        album: clean_tag(song.tag.album || song.tag2.TALB),
        year: clean_tag(song.tag.year || song.tag2.TYER || 0),
        track_nr: clean_tag(song.tag.track_nr || song.tag2.TRCK),
        genre: clean_tag(song.tag.genre_s || song.tag2.TCON, remove_regex: /\(\d*\)/)
      }
      f_song[:decade] = compute_decade(f_song[:year])

      unless valid_tags?(f_song)
        missing = missing_tags(f_song)
        prompt = "File #{f_song[:path]} has no proper tags, missing: #{missing}, do you want to move it to another folder? (y/n)"
        if MediaLibrarian.app.speaker.ask_if_needed(prompt, move_untagged.to_s != '' ? 1 : 0, 'y') == 'y'
          destination_folder = MediaLibrarian.app.speaker.ask_if_needed("Enter the full path of the folder to move the files into: ",
                                                      move_untagged.to_s != '' ? 1 : 0,
                                                      move_untagged.to_s)
          dest_subfolder = File.join(destination_folder, File.basename(File.dirname(f_song[:path])))
          FileUtils.mkdir_p(dest_subfolder)
          FileUtils.mv(file_entry[0], dest_subfolder)
        end
        next
      end

      sorter_name = "#{f_song[:genre]}#{f_song[:albumartist]}#{f_song[:year]}#{f_song[:album]}"
      ordered_collection[sorter_name] ||= []
      ordered_collection[sorter_name] << f_song

      CRITERIA_KEYS.each do |key|
        library[key] << f_song[key.to_sym] unless f_song[key.to_sym].nil? || library[key].include?(f_song[key.to_sym])
      end

      print "Processed song #{song_count} / #{files.count}\r"
    end

    MediaLibrarian.app.speaker.speak_up("Finished processing songs, now generating playlists...")
    collection = ordered_collection.sort_by { |k, _| k }
                                   .map { |_, songs| songs.sort_by { |s| s[:track_nr].to_i } }
    collection.shuffle! if random.to_i > 0
    collection.flatten!

    FileUtils.mkdir(folder) unless FileTest.directory?(folder)
    if remove_existing_playlists.to_i > 0
      FileUtils.search_folder(folder, { 'regex' => '.*\.m3u' }).each do |path|
        FileUtils.rm(path[0])
      end
    end

    CRITERIA_KEYS.each do |cr|
      prompt = "Do you want to generate playlists based on #{cr}? (y/n)"
      default_choice = criteria[cr].to_s != '' ? 1 : 0
      default_answer = criteria[cr].to_i > 0 ? 'y' : 'n'
      if MediaLibrarian.app.speaker.ask_if_needed(prompt, default_choice, default_answer) == 'y'
        if library[cr].nil? || library[cr].empty?
          MediaLibrarian.app.speaker.speak_up("No collection of #{cr} found!")
          next
        end
        MediaLibrarian.app.speaker.speak_up("Will generate playlists based on #{cr}")
        library[cr].each do |p|
          safe_name = "#{folder}/#{cr}s-#{p.gsub('/', '').gsub(/[^\u0000-\u007F]+/, '_').gsub(' ', '_')}".sub(/\/+\z/, '')
          generate_playlist(safe_name, collection.select { |s| s[cr.to_sym] == p })
        end
        MediaLibrarian.app.speaker.speak_up("#{library[cr].length} #{cr} playlists have been generated")
      end
    end
  end

  def self.generate_playlist(name, list)
    MediaLibrarian.app.speaker.speak_up("Generating playlist #{name}.m3u with #{list.count} elements")
    File.open("#{name}.m3u", "w:UTF-8") do |playlist|
      playlist.puts "#EXTM3U"
      list.each do |s|
        playlist.puts "#EXTINF:#{s[:length].round},#{s[:artist]} - #{s[:title]}"
        playlist.puts s[:path]
      end
    end
  end

  private

  def self.ensure_trailing_slash(folder)
    folder.end_with?('/') ? folder : "#{folder}/"
  end

  def self.clean_tag(tag_value, remove_regex: nil)
    return '' if tag_value.nil?
    cleaned = tag_value.to_s.strip.gsub(/\u0000/, '')
    cleaned = cleaned.gsub(remove_regex, '') if remove_regex
    cleaned
  end

  def self.compute_decade(year)
    decade = year.to_s[0...-1] + '0'
    decade.to_i.zero? ? nil : decade
  end

  def self.valid_tags?(f_song)
    f_song[:genre].to_s != '' && f_song[:artist].to_s != '' && f_song[:album].to_s != ''
  end

  def self.missing_tags(f_song)
    missing = []
    missing << 'genre' if f_song[:genre].to_s == ''
    missing << 'artist' if f_song[:artist].to_s == ''
    missing << 'album' if f_song[:album].to_s == ''
    missing.join(',')
  end
end