class Music

  def self.convert_songs(path, dest_file, input_format, output_format = 'mp3', qualities = nil)
    destination = dest_file.gsub(/(.*)\.[\w\d]{1,4}/, '\1' + ".#{output_format}")
    case input_format
      when 'flac' && output_format == 'mp3'
        f2m = Flac2mp3.new({'encoding' => qualities || ' -b320 -q0'})
        f2m.convert(path)
        FileUtils.mv(path.chomp('.flac') + '.mp3', destination)
    end
    destination
  end

  def self.create_playlists(folder:, criteria: {}, move_untagged: '', remove_existing_playlists: 1, random: 0)
    folder = "#{folder}/" unless folder[-1] == '/'
    ordered_collection = {}
    cpt = 0
    crs = ['artist', 'albumartist', 'album', 'year', 'decade', 'genre']
    library = {}
    $speaker.speak_up("Listing all songs in #{folder}")
    files = FileUtils.search_folder(folder, {'regex' => '.*\.[mM][pP]3'})
    files.each do |p_song|
      cpt += 1
      song = Mp3Info.open(p_song[0])
      f_song = {
          :path => p_song[0].gsub(folder, ''),
          :length => song.length,
          :artist => (song.tag.artist || song.tag2.TPE1).to_s.strip.gsub(/\u0000/, ''),
          :albumartist => (song.tag2.TPE2 || song.tag.artist || song.tag2.TPE1).to_s.strip.gsub(/\u0000/, ''),
          :title => (song.tag.title || song.tag2.TIT2).to_s.strip.gsub(/\u0000/, ''),
          :album => (song.tag.album || song.tag2.TALB).to_s.strip.gsub(/\u0000/, ''),
          :year => (song.tag.year || song.tag2.TYER || 0).to_s.strip.gsub(/\u0000/, ''),
          :track_nr => (song.tag.track_nr || song.tag2.TRCK).to_s.strip.gsub(/\u0000/, ''),
          :genre => (song.tag.genre_s || song.tag2.TCON).to_s.strip.gsub(/\(\d*\)/, '').gsub(/\u0000/, '')
      }
      f_song[:decade] = "#{f_song[:year][0...-1]}0"
      f_song[:decade] = nil if f_song[:decade].to_i == 0
      if f_song[:genre].to_s == '' || f_song[:artist].to_s == '' || f_song[:album].to_s == ''
        if $speaker.ask_if_needed("File #{f_song[:path]} has no proper tags, missing: #{'genre,' if f_song[:genre].to_s == ''}#{'artist,' if f_song[:artist].to_s == ''}#{'album,' if f_song[:album].to_s == ''} do you want to move it to another folder? (y/n)", move_untagged.to_s != '' ? 1 : 0, 'y') == 'y'
          destination_folder = $speaker.ask_if_needed("Enter the full path of the folder to move the files into: ", move_untagged.to_s != '' ? 1 : 0, move_untagged.to_s)
          FileUtils.mkdir_p("#{destination_folder}/#{File.basename(File.dirname(f_song[:path]))}")
          FileUtils.mv("#{p_song[0]}", "#{destination_folder}/#{File.basename(File.dirname(f_song[:path]))}/")
        end
        next
      end
      sorter_name = f_song[:genre].to_s+f_song[:albumartist].to_s+f_song[:year].to_s+f_song[:album].to_s
      ordered_collection[sorter_name] = [] if ordered_collection[sorter_name].nil?
      ordered_collection[sorter_name] << f_song
      crs.each do |cr|
        library[cr] = [] unless library[cr]
        library[cr] << f_song[cr.to_sym] unless f_song[cr.to_sym].nil? || library[cr].include?(f_song[cr.to_sym])
      end
      print "Processed song #{cpt} / #{files.count}\r"
    end
    $speaker.speak_up("Finished processing songs, now generating playlists...")
    collection = ordered_collection.sort_by { |k, _| k }.map { |x| x[1].sort_by { |s| s[:track_nr].to_i } }
    collection.shuffle! if random.to_i > 0
    collection.flatten!
    FileUtils.mkdir(folder) unless FileTest.directory?(folder)
    if remove_existing_playlists.to_i > 0
      FileUtils.search_folder(folder, {'regex' => '.*\.m3u'}).each do |path|
        FileUtils.rm(path[0])
      end
    end
    crs.each do |cr|
      if $speaker.ask_if_needed("Do you want to generate playlists based on #{cr}? (y/n)", criteria[cr].to_s != '' ? 1 : 0, criteria[cr].to_i > 0 ? 'y' : 'n') == 'y'
        if library[cr].nil? || library[cr].empty?
          $speaker.speak_up "No collection of #{cr} found!"
          next
        end
        $speaker.speak_up("Will generate playlists based on #{cr}")
        library[cr].each do |p|
          generate_playlist("#{folder}/#{cr}s-#{p.gsub('/', '').gsub(/[^\u0000-\u007F]+/, '_').gsub(' ', '_')}".gsub(/\/*$/, ''), collection.select { |s| s[cr.to_sym] == p })
        end
        $speaker.speak_up("#{library[cr].length} #{cr} playlists have been generated")
      end
    end
  end

  def self.generate_playlist(name, list)
    $speaker.speak_up("Generating playlist #{name}.m3u with #{list.count} elements")
    File.open("#{name}.m3u", "w:UTF-8") do |playlist|
      playlist.puts "#EXTM3U"
      list.each do |s|
        playlist.puts "\#EXTINF:#{s[:length].round},#{s[:artist]} - #{s[:title]}"
        playlist.puts "#{s[:path]}"
      end
    end
  end
end