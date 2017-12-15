class Book
  SHOW_MAPPING = {calibre_id: :calibre_id, full_name: :full_name, pubdate: :pubdate, series_name: :series_name,
                  ids: :ids, series_id: :series_id, series: :series, name: :name, identifier: :identifier}

  SHOW_MAPPING.values.each do |value|
    attr_accessor value
  end

  def initialize(opts)
    SHOW_MAPPING.each do |source, destination|
      send("#{destination}=", opts[source.to_s] || opts[source.to_sym] || fetch_val(source.to_s, opts))
    end
  end

  def fetch_val(valname, opts)
    case valname
      when 'calibre_id'
        opts[:id]
      when 'goodreads_id'
        opts['id']
      when 'ids'
        if calibre_id
          Hash[$calibre.get_rows('identifiers', {:book => calibre_id}).map { |i| [i[:type].to_s, i[:val].to_s] }]
        elsif opts['isbn13'] || opts['gr_ids']
          {'isbn' => opts['isbn13'] || opts['gr_ids']}
        else
          {}
        end
      when 'full_name'
        opts[:name] || opts[:title] || opts['title'] || opts['name']
      when 'name'
        n = full_name.match(/#{series_name}[- \._]{1,3}[TS]\d{1,4}[ -\._]{1,3}(.+)/)
        n = full_name.match(/(.*)\(.+, \#\d+\)$/) if n.nil?
        (n ? n[1] : '').strip
      when 'pubdate'
        (opts['publication_year'] ? Date.new(opts['publication_year'].to_i, (opts['publication_month'] || 1).to_i, (opts['publication_day'] || 1).to_i) : nil)
      when 'identifier'
        "book#{series_name}#{name}"
      when 'series_name'
        m = full_name.match(/\((.+), \#\d+\)$/)
        m ? m[1] : ''
      when 'series'
        if series_name.to_s != ''
          {:series_name => series_name}
        else
          nil
        end
    end
  end

  def series_name
    return @series_name if @series_name
    series_link = $calibre.get_rows('books_series_link', {:book => calibre_id}).first
    series = series_link.nil? ? [] : $calibre.get_rows('series', {:id => series_link[:series]})
    @series_name = series.empty? ? '' : series.first[:name]
  end

  def self.book_search(title, no_prompt = 0, isbn = '')
    cached = Cache.cache_get('book_search', title.to_s + isbn.to_s)
    return cached if cached
    if isbn.to_s != ''
      book = ($goodreads.book_by_isbn(isbn) rescue nil)
      book = new(book) if book
      exact_title = book ? book.name : title
      Cache.cache_add('book_search', title.to_s + isbn.to_s, [exact_title, book], book)
      return exact_title, book unless book.nil?
    end
    books = $goodreads.search_books(title)
    rs = []
    if books['results'] && books['results']['work']
      bs = books['results']['work'].is_a?(Array) ? books['results']['work'] : [books['results']['work']]
      bs.each do |b|
        next unless b['best_book']
        rs << {:title => b['best_book']['title'], :url => '', :id => b['best_book']['id']}
      end
    end
    exact_title, book = MediaInfo.media_chose(
        title,
        rs,
        {'name' => :title, 'url' => :url},
        'books',
        no_prompt.to_i
    )
    unless book.nil?
      book = $goodreads.book(book[:id])
      if book
        book = new(book)
        exact_title = book.name
      end
    end
    Cache.cache_add('book_search', title.to_s + isbn.to_s, [exact_title, book], book)
    return exact_title, book
  rescue => e
    $speaker.tell_error(e, "Book.book_search")
    Cache.cache_add('book_search', title.to_s + isbn.to_s, [title, nil], nil)
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

  def self.identify_episodes_numbering(filename)
    id = filename.match(/\( #(\d{1,4})\)$/)
    id = id[1] if id
    nb = id.to_i
    nb
  end

  def self.existing_books(no_prompt = 0)
    existing_books = {}
    $calibre.get_rows('books').each do |b|
      book = new(b)
      existing_books = Library.parse_media(
          {:type => 'books', :name => book.full_name},
          'books',
          no_prompt,
          existing_books,
          {},
          {},
          {},
          '',
          book.ids
      )
    end
    existing_books
  end
end