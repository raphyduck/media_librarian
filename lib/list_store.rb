require 'yaml'

module ListStore

  # Import a CSV into a list (replacing previous rows by default)
  def self.import_csv(list_name:, csv_path:, replace: 1)
    raise ArgumentError, "CSV file not found: #{csv_path}" unless File.file?(csv_path)
    rows = []
    CSV.foreach(csv_path, headers: true) do |row|
      title = row['title']&.to_s&.strip
      type = row['type']&.to_s&.strip
      next if title.nil? || title.empty?
      year  = row['year']&.to_s&.strip
      year_i = (year && year =~ /^\d{4}$/) ? year.to_i : nil
      alts  = row['alt_titles']&.to_s&.strip
      url   = row['url']&.to_s&.strip
      rows << [list_name.to_s.strip, type, title, year_i, alts, url, row['imdb_id'], row['tmdb_id'], Time.now.to_i]
    end
    return 0 if rows.empty?
    MediaLibrarian.app.db.insert_rows('media_lists', rows, replace)
  rescue => e
    MediaLibrarian.app.speaker.tell_error(e, "ListStore.import_csv") rescue nil
    0
  ensure
  end

  def self.upsert_item(list_name:, title:, type:, year: nil, alt_titles: nil, url: nil, imdb: nil, tmdb: nil)
    raise ArgumentError, 'title is required' if title.to_s.strip.empty?

    MediaLibrarian.app.db.insert_row(
      'media_lists',
      {
        list_name: list_name,
        type: type,
        title: title,
        year: year,
        alt_titles: alt_titles,
        url: url,
        imdb: imdb,
        tmdb: tmdb,
        created_at: Time.now
      },
      1
    )
  rescue => e
    MediaLibrarian.app.speaker.tell_error(e, "ListStore.upsert_item(#{list_name})") rescue nil
    nil
  end

  def self.delete_item(list_name:, title:, year: nil, type: nil)
    return 0 if title.to_s.strip.empty?

    conditions = { list_name: list_name, title: title }
    conditions[:year] = year if year.to_s != ''
    conditions[:type] = type if type.to_s != ''
    MediaLibrarian.app.db.delete_rows('media_lists', conditions)
  rescue => e
    MediaLibrarian.app.speaker.tell_error(e, "ListStore.delete_item(#{list_name})") rescue nil
    0
  end

  def self.fetch_list(list_name)
    MediaLibrarian.app.db.get_rows('media_lists', {:list_name => list_name})
  rescue => e
    MediaLibrarian.app.speaker.tell_error(e, "ListStore.fetch_list(#{list_name})") rescue nil
    []
  end

  def self.download_entries(list_name:, file_path: nil)
    entries = fetch_list(list_name)
    return entries if file_path.to_s.empty? || !File.file?(file_path)

    file_data = YAML.safe_load(File.read(file_path)) || []
    file_entries = Array(file_data).select { |row| row.is_a?(Hash) }
    file_entries.each do |row|
      entries << {
        list_name: list_name,
        type: row['type'] || row[:type],
        title: row['title'] || row[:title],
        year: row['year'] || row[:year],
        alt_titles: row['alt_titles'] || row[:alt_titles],
        url: row['url'] || row[:url],
        imdb: row['imdb'] || row[:imdb],
        tmdb: row['tmdb'] || row[:tmdb],
        created_at: Time.now
      }
    end
    entries
  rescue => e
    MediaLibrarian.app.speaker.tell_error(e, "ListStore.download_entries(#{list_name})") rescue nil
    []
  end
end
