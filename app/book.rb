class Book
  SHOW_MAPPING = {calibre_id: :calibre_id, filename: :filename, series_id: :series_id, series_nb: :series_nb, full_name: :full_name,
                  ids: :ids, series: :series, series_name: :series_name, name: :name, pubdate: :pubdate}

  @books_library = {}

  SHOW_MAPPING.values.each do |value|
    attr_accessor value
  end

  def initialize(opts)
    SHOW_MAPPING.each do |source, destination|
      send("#{destination}=", opts[source.to_s] || opts[source.to_sym] || fetch_val(source.to_s, Utils.recursive_typify_keys(opts)))
    end
    detect_series(opts)
  end

  def detect_series(opts)
    if @series_id.nil?
      series_link = calibre_id.to_i != 0 ? $calibre.get_rows('books_series_link', {:book => calibre_id}).first : nil
      @series_id = series_link ? series_link[:series] : nil
    end
    @series_name, @name, _ = Book.detect_book_title(filename) unless @series_name.to_s != ''
    if @series.nil? && @series_id.to_s != '' && @series_name.to_s != ''
      @series = BookSeries.new($calibre.get_rows('series', {:id => @series_id}).first)
    elsif @series.nil? && Book.books_library[:book_series]
      s = if Book.books_library[:book_series]
            Book.books_library[:book_series].select do |ss, _|
              filename.match(Regexp.new(StringUtils.regexify(ss.to_s) + "[#{SPACE_SUBSTITUTE}]", Regexp::IGNORECASE))
            end.first
          else
            nil
          end
      if s
        @series_name = s[0]
        @series = s[1]
      end
    end
    if @series.nil?
      t, @series = BookSeries.book_series_search(filename, ids)
      @series_name = t if @series
      @series = nil if @series.is_a?(Hash) && @series.empty?
    end
    @series_nb = Book.identify_episodes_numbering(filename) if @series_nb.nil? && !@series.nil?
    @series_nb = opts[:series_index].to_f if @series_nb.to_i == 0 && @series_id.to_s != '' && !@series.nil? && opts[:series_index]
    @full_name = "#{@series_name}#{' - ' if @series_name.to_s != ''}#{'T' + @series_nb.to_s if @series_name.to_s != ''}#{' - ' if @series_name.to_s != ''}#{@name}" if @full_name.nil?
  end

  def fetch_val(valname, opts)
    case valname
      when 'calibre_id'
        opts[:id] if opts[:from_calibre].to_i > 0
      when 'filename'
        (opts[:name] || opts[:title]).strip
      when 'ids'
        if calibre_id
          is = Hash[$calibre.get_rows('identifiers', {:book => calibre_id}).map { |i| [i[:type].to_s, i[:val].to_s] }]
        elsif opts[:isbn13] || opts[:gr_ids]
          is = {'isbn' => opts[:isbn13] || opts[:gr_ids]}
        else
          is = {}
        end
        is.merge!({'goodreads' => opts[:id]}) if opts[:id] && opts[:from_calibre].to_i == 0
        is
      when 'pubdate'
        (opts[:publication_year] ? Date.new(opts[:publication_year].to_i, (opts[:publication_month] || 1).to_i, (opts[:publication_day] || 1).to_i) : nil)
    end
  end

  def identifier
    "book#{series_name}#{series.goodread_id.to_s if series.to_s != ''}T#{series_nb}"
  end

  def self.book_search(title, no_prompt = 0, ids = {})
    cache_name = title.to_s + ids['isbn'].to_s
    rs, book, exact_title = [], nil, title
    Utils.lock_block("#{__method__}_#{cache_name}") {
      cached = Cache.cache_get('book_search', cache_name)
      return cached if cached
      if ids['isbn'].to_s != ''
        book = ($goodreads.book_by_isbn(ids['isbn']) rescue nil)
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
              Utils.recursive_typify_keys(b['best_book'])
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
        if book
          book = new(book)
        else
          book = new({:filename => title})
        end
      end
      Cache.cache_add('book_search', cache_name, [exact_title, book], book)
    }
    return exact_title, book
  rescue => e
    $speaker.tell_error(e, Utils.arguments_dump(binding))
    Cache.cache_add('book_search', cache_name, [title, nil], nil)
    return title, nil
  end

  def self.books_library
    @books_library
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
    $speaker.speak_up("Folder #{File.basename(path)} compressed to #{output_format} comic") if skip_compress.to_i == 0
    return skip_compress
  end

  def self.convert_comics(path, name, input_format, output_format, dest_file, no_warning = 0)
    skipping = 0
    FileUtils.mkdir(name) unless File.exist?(name)
    Dir.chdir(Env.pretend? ? '.' : name) do
      case input_format
        when 'pdf'
          if Env.pretend?
            $speaker.speak_up "Would extract images from pdf"
          else
            extractor = ExtractImages::Extractor.new
            extracted = 0
            PDF::Reader.open('../' +File.basename(path)) do |reader|
              reader.pages.each do |page|
                extracted += extractor.page(page)
              end
            end
            unless extracted > 0
              $speaker.ask_if_needed("WARNING: Error extracting images, skipping #{name}! Press any key to continue!", no_warning)
              skipping = 1
            end
          end
        when 'cbr', 'cbz'
          FileUtils.extract_archive(input_format, '../' + File.basename(path), '.')
        else
          $speaker.speak_up('Nothing to do, skipping')
          skipping = 1
      end
      FileUtils.search_folder('.').each do |f|
        if File.dirname(f[0]) != Dir.pwd
          if FileUtils.get_path_depth(f[0], Dir.pwd).to_i > 1
            FileUtils.mv(f[0], File.dirname(f[0]) + '/..')
          end
        end
        ff = './' + File.basename(f[0])
        nf = ff.clone
        nums = ff.scan(/(?=(([^\d]|^)(\d+)[^\d]))/)
        nums.each do |n|
          if n[2].length < 3
            nf.gsub!(/([^\d]|^)(#{n[2]})([^\d])/, '\1' + format('%03d', n[2].to_i) + '\3')
          end
        end
        FileUtils.mv(ff, nf) if ff != nf
      end
    end
    skipping = if Env.pretend?
                 $speaker.speak_up "Would compress '#{name}' to '#{dest_file}' (#{output_format})"
                 1
               else
                 compress_comics(path: name, destination: dest_file, output_format: output_format, remove_original: 1, skip_compress: skipping)
               end
    skipping
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
        nb = id[5].to_s
      when 'h'
        nb = ('0.' << id[4].to_s)
    end
    nb
  end

  def self.existing_books(no_prompt = 0)
    return @books_library if $calibre.nil?
    bl = {}
    $calibre.get_rows('books').each do |b|
      book = new(b.merge({:from_calibre => 1}))
      bl = Library.parse_media(
          {:type => 'books', :name => book.filename},
          'books',
          no_prompt,
          bl,
          {},
          {},
          {},
          '',
          book.ids,
          book,
          book.full_name
      )
    end
    @books_library = bl
    @books_library
  end
end