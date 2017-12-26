class Book
  SHOW_MAPPING = {calibre_id: :calibre_id, filename: :filename, series_id: :series_id, series_nb: :series_nb,
                  full_name: :full_name, ids: :ids, series: :series, name: :name, pubdate: :pubdate}

  SHOW_MAPPING.values.each do |value|
    attr_accessor value
  end

  def initialize(opts)
    SHOW_MAPPING.each do |source, destination|
      send("#{destination}=", opts[source.to_s] || opts[source.to_sym] || fetch_val(source.to_s, opts))
    end
  end

  def fetch_val(valname, opts)
    #TODO: Fetch episode number from DB
    case valname
      when 'calibre_id'
        opts[:id]
      when 'filename'
        (opts[:name] || opts[:title] || opts['title'] || opts['name']).strip
      when 'full_name'
        _, name, _ = Book.detect_book_title(filename)
        "#{series_name}#{' - ' if series_name.to_s != ''}#{series_name if series_name.to_s != ''}#{' - ' if series_name.to_s != ''}#{name}"
      when 'ids'
        if calibre_id
          is = Hash[$calibre.get_rows('identifiers', {:book => calibre_id}).map { |i| [i[:type].to_s, i[:val].to_s] }]
        elsif opts['isbn13'] || opts['gr_ids']
          is = {'isbn' => opts['isbn13'] || opts['gr_ids']}
        else
          is = {}
        end
        is.merge!({'goodreads' => opts['id']}) if opts['id']
        is
      when 'name'
        _, name, _ = Book.detect_book_title(filename)
        name
      when 'pubdate'
        (opts['publication_year'] ? Date.new(opts['publication_year'].to_i, (opts['publication_month'] || 1).to_i, (opts['publication_day'] || 1).to_i) : nil)
      when 'series_name'
        m = full_name.match(/\((.+), \#\d+\)$/)
        m ? m[1] : ''
      when 'series_nb'
        nb = Book.identify_episodes_numbering(filename)
        nb = opts[:series_index].to_f if nb.to_i == 0 && series_id.to_s != ''
        nb
      when 'series_id'
        series_link = $calibre.get_rows('books_series_link', {:book => calibre_id}).first
        series_link ? series_link[:series] : nil
      when 'series'
        if series_id.to_s != '' && series_name.to_s != ''
          BookSeries.new({'name' => series_name})
        elsif calibre_id
          t, s = BookSeries.book_series_search(filename, 1, ids['isbn'])
          @series_name = t if s && !s.empty?
          s = nil if s&.empty?
          s
        end
    end
  end

  def identifier
    "book#{series_name}T#{series_nb}"
  end

  def series_name
    if @series_name
      return @series_name
    end
    series = series_id.nil? ? [] : $calibre.get_rows('series', {:id => series_id})
    @series_name = series.empty? ? '' : series.first[:name]
    @series_name
  end

  def self.book_search(title, no_prompt = 0, isbn = '')
    cache_name = title.to_s + isbn.to_s
    cached = Cache.cache_get('book_search', cache_name)
    return cached if cached
    rs, book, exact_title = [], nil, title
    if isbn.to_s != ''
      book = ($goodreads.book_by_isbn(isbn) rescue nil)
      if book
        book = new(book)
        exact_title = book.name
      end
    end
    if book.nil?
      books = $goodreads.search_books(title)
      if books['results'] && books['results']['work']
        bs = books['results']['work'].is_a?(Array) ? books['results']['work'] : [books['results']['work']]
        rs = bs.map do |b|
          if b['best_book']
            sname, tname, _ = detect_book_title(b['best_book']['title'])
            sname = tname if sname == ''
            b['best_book']['title'] = sname
            Utils.recursive_symbolize_keys(b['best_book'])
          end
        end.select { |b| !b.nil? }
      end
      exact_title, book = MediaInfo.media_chose(
          title,
          rs.uniq,
          {'name' => :title, 'url' => :url},
          'books',
          no_prompt.to_i
      )
      book = new(book) if book
    end
    Cache.cache_add('book_search', cache_name, [exact_title, book], book)
    return exact_title, book
  rescue => e
    $speaker.tell_error(e, "Book.book_search")
    Cache.cache_add('book_search', cache_name, [title, nil], nil)
    return title, nil
  end

  def self.compress_comics(path:, destination: '', output_format: 'cbz', remove_original: 1, skip_compress: 0)
    destination = path.gsub(/\/$/, '') + '.' + output_format if destination.to_s == ''
    case output_format
      when 'cbz'
        FileUtils.compress_archive(path, destination) if skip_compress.to_i == 0
      else
        $speaker.speak_up('Nothing to do, skipping')
        skip_compress = 1
    end
    FileUtils.rm_r(path) if remove_original.to_i > 0
    $speaker.speak_up("Folder #{File.basename(path)} compressed to #{output_format} comic")
    return skip_compress
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
      FileUtils.search_folder(path, {'regex' => ".*\.#{input_format}"}).each do |f|
        convert_comics(path: f[0], input_format: input_format, output_format: output_format, no_warning: 1, rename_original: rename_original, move_destination: move_destination)
      end
    else
      skipping = 0
      Dir.chdir(File.dirname(path)) do
        name = File.basename(path).gsub(/(.*)\.[\w]{1,4}/, '\1')
        dest_file = "#{move_destination}/#{name.gsub(/^_?/, '')}.#{output_format}"
        return if File.exist?(dest_file)
        $speaker.speak_up("Will convert #{name} to #{output_format.to_s.upcase} format #{dest_file}")
        FileUtils.mkdir(name) unless File.exist?(name)
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
              FileUtils.extract_archive(input_format, '../' +File.basename(path), '.')
            else
              $speaker.speak_up('Nothing to do, skipping')
              skipping = 1
          end
        end
        skipping = compress_comics(path: name, destination: dest_file, output_format: output_format, remove_original: 1, skip_compress: skipping)
        return if skipping > 0
        FileUtils.mv(File.basename(path), "_#{File.basename(path)}_") if rename_original.to_i > 0
        $speaker.speak_up("#{name} converted!")
      end
    end
  rescue => e
    $speaker.tell_error(e, "Library.convert_comics")
    name.to_s != '' && Dir.exist?(File.dirname(path) + '/' + name) && FileUtils.rm_r(File.dirname(path) + '/' + name)
  end

  def self.detect_book_title(name)
    series_name, id_info = '', ''
    m = name.match(REGEX_BOOK_NB)
    nb = identify_episodes_numbering(name)
    if m
      series_name = m[1].to_s.gsub(/- ?$/, '').strip if m[1]
      name = m[5].to_s.strip if m[2]
    else
      m = name.match(REGEX_BOOK_NB2)
      series_name = m[2].to_s.gsub(/- ?$/, '').strip if m && m[2]
      name = m[1].to_s.strip if m && m[2]
    end
    if series_name.to_s != ''
      if nb.to_i > 0
        id_info = " - T#{nb}"
      else
        id_info = " - #{name}"
      end
    end
    return series_name, name, id_info
  end

  def self.identify_episodes_numbering(filename)
    id = filename.match(REGEX_BOOK_NB2)
    id = filename.match(REGEX_BOOK_NB) if id.nil?
    nb = 0
    return nb if id.nil?
    case id[3].to_s[0].downcase
      when 't', '#'
        nb = id[4].to_i
      when 'h'
        nb = ('0.' << id[4].to_s)
    end
    nb
  end

  def self.existing_books(no_prompt = 0)
    #TODO: Finish this, ensure return a hash of individual book + hash [:book_series] = list of all series
    existing_books = {}
    $calibre.get_rows('books').each do |b|
      book = new(b)
      existing_books = Library.parse_media(
          {:type => 'books', :name => book.filename},
          'books',
          no_prompt,
          existing_books,
          {},
          {},
          {},
          '',
          book.ids,
          book,
          book.full_name
      )
    end
    existing_books
  end
end