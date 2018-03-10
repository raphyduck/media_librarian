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
    if @series.nil? && opts[:no_series_search].to_i == 0
      t, @series = BookSeries.book_series_search(filename, 1, ids)
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

  def self.book_search(title, no_prompt = 0, ids = {}, no_series_search = 0)
    cache_name = title.to_s + ids['isbn'].to_s
    cached = Cache.cache_get('book_search', cache_name)
    return cached if cached
    rs, book, exact_title = [], nil, title
    if ids['isbn'].to_s != ''
      book = ($goodreads.book_by_isbn(ids['isbn']) rescue nil)
      if book
        book = new(book.merge({:no_series_search => no_series_search}))
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
        book = new(book.merge({:no_series_search => no_series_search}))
      else
        book = new({:filename => title}.merge({:no_series_search => no_series_search}))
      end
    end
    Cache.cache_add('book_search', cache_name, [exact_title, book], book)
    return exact_title, book
  rescue => e
    $speaker.tell_error(e, "Book.book_search")
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

  def self.convert_comics(path:, input_format:, output_format:, no_warning: 0, rename_original: 1, move_destination: '', search_pattern: '')
    name, results = '', []
    move_destination = '.' if move_destination.to_s == ''
    valid_inputs = ['cbz', 'pdf', 'cbr']
    valid_outputs = ['cbz']
    return $speaker.speak_up("Invalid input format, needs to be one of #{valid_inputs}") unless valid_inputs.include?(input_format)
    return $speaker.speak_up("Invalid output format, needs to be one of #{valid_outputs}") unless valid_outputs.include?(output_format)
    return if no_warning.to_i == 0 && input_format == 'pdf' && $speaker.ask_if_needed("WARNING: The images extractor is incomplete, can result in corrupted or incomplete CBZ file. Do you want to continue? (y/n)") != 'y'
    return $speaker.speak_up("#{path.to_s} does not exist!") unless File.exist?(path)
    if FileTest.directory?(path)
      FileUtils.search_folder(path, {'regex' => ".*#{search_pattern.to_s + '.*' if search_pattern.to_s != ''}\.#{input_format}"}).each do |f|
        results += convert_comics(path: f[0], input_format: input_format, output_format: output_format, no_warning: 1, rename_original: rename_original, move_destination: move_destination)
      end
    elsif search_pattern.to_s != ''
      $speaker.speak_up "Can not use search_pattern if path is not a directory"
      return results
    else
      skipping = 0
      Dir.chdir(File.dirname(path)) do
        name = File.basename(path).gsub(/(.*)\.[\w\d]{1,4}/, '\1')
        dest_file = "#{move_destination}/#{name.gsub(/^_?/, '')}.#{output_format}"
        final_file = dest_file
        if File.exist?(File.basename(dest_file))
          if input_format == output_format
            dest_file = "#{move_destination}/#{name.gsub(/^_?/, '')}.proper.#{output_format}"
          else
            return results
          end
        end
        $speaker.speak_up("Will convert #{name} to #{output_format.to_s.upcase} format #{dest_file}")
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
                nf.gsub!(/([^\d]|^)(#{n[2]})([^\d])/, '\1' + format('%03d', n[2]) + '\3')
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
        return results if skipping > 0
        FileUtils.mv(File.basename(path), "_#{File.basename(path)}_") if rename_original.to_i > 0
        FileUtils.mv(dest_file, final_file) if final_file != dest_file
        $speaker.speak_up("#{name} converted!")
        results << final_file
      end
    end
    results
  rescue => e
    $speaker.tell_error(e, "Library.convert_comics")
    name.to_s != '' && Dir.exist?(File.dirname(path) + '/' + name) && FileUtils.rm_r(File.dirname(path) + '/' + name)
    []
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
        nb = id[5].to_i
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