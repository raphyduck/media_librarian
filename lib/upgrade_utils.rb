class UpgradeUtils

  def self.check_unidentified_media(type:, folder:, no_prompt: 0, folder_hierarchy: {})
    not_found, found = [], []
    FileUtils.search_folder(folder).each do |f|
      next unless f[0].match(Regexp.new(VALID_VIDEO_EXT))
      item_name, item = Metadata.identify_title(f[0], type, no_prompt, (folder_hierarchy[type] || FOLDER_HIERARCHY[type]), folder)
      if item.nil?
        not_found << File.dirname(f[0]).sub(/\/season \d+\/?/i, '')
      else
        found << {:n => item_name, :p => File.dirname(f[0]).sub(/\/season \d+\/?/i, '')}
      end
    end
    MediaLibrarian.app.speaker.speak_up "Identified folders:"
    found.uniq.each { |f| MediaLibrarian.app.speaker.speak_up "File(s) in folder '#{f[:p]}' identified as '#{f[:n]}'" }
    MediaLibrarian.app.speaker.speak_up "Unidentified folders:"
    not_found.uniq.each { |f| MediaLibrarian.app.speaker.speak_up("File(s) in folder '#{f}' not identified!") }
    return 0
  end

  def self.update_torrents_identifiers(type:)
    MediaLibrarian.app.db.get_rows('torrents').each do |t|
      next unless (type == 'shows' && t[:identifier].match(/^tv.*/)) || (type == 'movies' && t[:identifier].match(/^movie.*/))
      torrent = Cache.object_unpack(t[:tattributes])
      full_name, ids, _ = Metadata.parse_media_filename(torrent[:name], type, nil, '', 1)
      next if ids.empty? || full_name == ''
      id = ids.join
      torrent[:identifier] = id
      torrent[:identifiers] = ids
      MediaLibrarian.app.db.update_rows('torrents', {:identifier => id, :identifiers => ids, :tattributes => Cache.object_pack(torrent)}, {:name => torrent[:name]})
    end
    0
  end

  def self.update_torrents
    MediaLibrarian.app.db.get_rows('torrents').each do |t|
      next unless [1, 2].include?(t[:status])
      category = case t[:identifier]
                 when /^tv.*/
                   "shows"
                 when /^movie.*/
                   "movies"
                 when /^book.*/
                   "book"
                 end
      torrent = Cache.object_unpack(t[:tattributes])
      torrent[:category] = category
      next if category.nil?
      MediaLibrarian.app.speaker.speak_up "Updating torrent '#{torrent[:name]}' with category '#{torrent[:category]}'"
      MediaLibrarian.app.db.update_rows('torrents', {:tattributes => Cache.object_pack(torrent)}, {:name => torrent[:name]})
    end
    0
  end
end