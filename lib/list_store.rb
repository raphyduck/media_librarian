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
    $db.insert_rows('media_lists', rows, replace)
  rescue => e
    $speaker.tell_error(e, "ListStore.import_csv") rescue nil
    0
  ensure
  end

  def self.fetch_list(list_name)
    $db.get_rows('media_lists', {:list_name => list_name})
  rescue => e
    $speaker.tell_error(e, "ListStore.fetch_list(#{list_name})") rescue nil
    []
  end
end
