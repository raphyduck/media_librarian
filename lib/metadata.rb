require File.dirname(__FILE__) + '/vash'

# Ruby 3 removed the obsolete URI.escape method.  To properly percent‑encode
# strings for display or inclusion in URLs we use
# URI.encode_www_form_component instead.  Require the `uri` library so the
# URI module is available.
require 'uri'
require 'timeout'

class Metadata

  def self.detect_metadata(name, type)
    title, metadata, ids = name, name, ''
    case type
    when 'movies'
      m = name.match(/(.*[#{SPACE_SUBSTITUTE}]\(?\d{4}\)?)([#{SPACE_SUBSTITUTE}](.*)|$)/i)
      if m
        title = m[1]
        metadata = m[3]
      end
    when 'shows'
      title = name.gsub(/[#{SPACE_SUBSTITUTE}][Ss](eason|aison)[#{SPACE_SUBSTITUTE}](\d{1,4})[#{SPACE_SUBSTITUTE}]/) { " S#{'%02d' % $2} " }
      ids = File.basename(title).scan(Regexp.new(BASIC_EP_MATCH)).uniq
      unless ids.empty?
        metadata = title.gsub(/#{ids.first[0]}(.*)/, '\1')
        title.gsub!(/#{ids.first[0]}.*/, ' ')
      end
      ids = ids.map { |i| i[0] if i[0] }.join
      title.gsub!(/^(\[[^\]]+\])?(.*)/, '\2')
    end
    return title, metadata, ids
  end

  def self.detect_real_title(name, type, id_info = 0, complete = 1)
    name = name.clone.to_s.encode("UTF-8")
    name.gsub!(Regexp.new(VALID_VIDEO_EXT), '\1')
    name, _, ids = detect_metadata(name, type)
    if complete.to_i == 0
      name.gsub!(/[#{SPACE_SUBSTITUTE}]\((US|UK)\)[#{SPACE_SUBSTITUTE}]{0,2}$/, '')
      name.gsub!(/(.*)[#{SPACE_SUBSTITUTE}]\(?((19|20)(\d{2})|0)\)?([#{SPACE_SUBSTITUTE}]|$)/i, '\1')
      name.gsub!(/[\(\)\[\]]/, '')
    end
    name.gsub!(/\((i+|video|tv#{SPACE_SUBSTITUTE}.+)\)/i, '')
    name.gsub!(/(&#x27;|&#039;)/, '')
    name << "#{ids}" if id_info.to_i > 0 && defined?(ids)
    name.to_s.gsub(/[#{SPACE_SUBSTITUTE}]+/, ' ').strip
  end

  def self.identify_metadata(filename, type, item_name = '', item = nil, no_prompt = 0, folder_hierarchy = {}, base_folder = Dir.home, qualities = [])
    metadata = {}
    ep_filename = File.basename(filename)
    file = { :name => filename }
    full_name, identifiers, info = parse_media_filename(
      filename,
      type,
      item,
      item_name,
      no_prompt,
      folder_hierarchy,
      base_folder,
      file
    )
    return metadata if ['shows', 'movies'].include?(type) && (identifiers.empty? || full_name == '')
    metadata['quality'] = Quality.parse_qualities(qualities.join('.') != '' ? ".#{qualities.join('.')}." : ep_filename, VALID_QUALITIES, info[:language], type).join('.')
    metadata['proper'], _ = Quality.identify_proper(ep_filename)
    metadata['extension'] = FileUtils.get_extension(ep_filename)
    metadata['is_found'] = true
    metadata['part'] = file[:parts].map { |p| "part#{p}" }.join('.') unless file[:parts].nil?
    case type
    when 'shows'
      tv_episodes = BusVariable.new('tv_episodes', Vash)
      _, tv_episodes[info[:series_name], CACHING_TTL] = TvSeries.tv_episodes_search(info[:series_name], no_prompt, info[:show]) if tv_episodes[info[:series_name]].nil?
      episode_name = []
      info[:episode].each do |n|
        tvdb_ep = !tv_episodes[info[:series_name]].empty? && n[:ep] ? tv_episodes[info[:series_name]].select { |e| e.season_number.to_i == n[:s].to_i && e.number.to_i == n[:ep].to_i }.first : nil
        episode_name << (tvdb_ep.nil? ? '' : tvdb_ep.name.to_s.downcase)
      end
      metadata['episode_name'] = episode_name.join(' ')[0..50]
      metadata['is_found'] = (info[:episode_numbering].to_s != '')
    when 'movies'
      metadata['movies_name'] = full_name
    end
    metadata.merge!(Utils.recursive_typify_keys({ :full_name => full_name, :identifiers => identifiers }.merge(info.select { |k, _| ![:show, :movie].include?(k) }), 0))
    metadata
  end

  def self.identify_title(filename, type, no_prompt = 0, folder_level = 2, base_folder = Dir.home, ids = {})
    ids = {} if ids.nil?
    title, item, original_filename = nil, nil, nil
    media_folders = BusVariable.new('media_folders', Hash)
    media_folders[type] = Vash.new unless media_folders[type]
    in_path = FileUtils.is_in_path(media_folders[type].keys, filename)
    return media_folders[type][in_path] if in_path && !media_folders[type][in_path].nil?
    filename, _ = FileUtils.get_only_folder_levels(filename.gsub(base_folder, ''), folder_level.to_i)
    r_folder, jk = filename, 0
    while item.nil?
      t_folder, r_folder = FileUtils.get_top_folder(r_folder)
      next if t_folder.to_s == ''
      case type
      when 'movies'
        if item.nil? && t_folder == r_folder
          original_filename = t_folder
          t_folder = detect_real_title(t_folder, type)
          jk += 1
        end
        title, item = Movie.movie_search(t_folder, no_prompt, original_filename, ids)
      when 'shows'
        if item.nil? && t_folder == r_folder
          original_filename = t_folder
          t_folder = detect_real_title(t_folder, type)
          jk += 1
        end
        title, item = TvSeries.tv_show_search(t_folder, no_prompt, original_filename, ids)
      else
        title = File.basename(filename).downcase.gsub(REGEX_QUALITIES, '').gsub(/\.{\w{2,4}$/, '')
      end
      break if t_folder == r_folder || jk > 0
    end
    cache_name = base_folder.to_s + filename.gsub(r_folder, '')
    media_folders[type][cache_name, CACHING_TTL] = [title, item] unless cache_name.to_s == ''
    MediaLibrarian.app.speaker.speak_up("#{Utils.arguments_dump(binding)}= '#{title}', nil", 0) if item.nil?
    return title, item
  end

  def self.identify_release_year(filename)
    m = filename.strip.match(/[\( \.](\d{4})[\) \.]?$/) rescue nil
    y = m ? m[1].to_i : 0
    y = 0 if y > Time.now.year + 50
    y
  end

  def self.match_titles(title, target_title, year, target_year, category)
    ep_match = true
    if category.to_s == 'shows'
      _, title_ep_ids = TvSeries.identify_tv_episodes_numbering(title)
      _, target_title_ep_ids = TvSeries.identify_tv_episodes_numbering(target_title)
      ep_match = ((title_ep_ids - target_title_ep_ids) | (target_title_ep_ids - title_ep_ids)).empty?
    end
    t = detect_real_title(title.strip, category, 0, 0)
    tt = detect_real_title(target_title.strip, category, 0, 0)
    tt = StringUtils.clean_search(tt)
    t = StringUtils.clean_search(t)
    regex_match = t.match(
      Regexp.new(
        "^(\[.{1,2}\])?([#{SPACE_SUBSTITUTE}&]|and|et){0,2}" + StringUtils.regexify(tt) + "([#{SPACE_SUBSTITUTE}&\!\?]){0,3}$",
        Regexp::IGNORECASE)
    )
    fallback_match = regex_match || tokens_match_with_optional_numbers?(t, tt)
    m = fallback_match && ep_match && Utils.match_release_year(target_year, year)
    MediaLibrarian.app.speaker.speak_up "#{Utils.arguments_dump(binding)} is FALSE" if !m && Env.debug?
    m
  end

  def self.tokens_match_with_optional_numbers?(title, target)
    t_tokens = title.to_s.downcase.split(/\s+/).reject(&:empty?)
    tt_tokens = target.to_s.downcase.split(/\s+/).reject(&:empty?)
    i = j = 0
    while i < t_tokens.length && j < tt_tokens.length
      a = t_tokens[i]
      b = tt_tokens[j]
      if a == b
        i += 1
        j += 1
      elsif optional_number_token?(a) && !optional_number_token?(b)
        i += 1
      elsif optional_number_token?(b) && !optional_number_token?(a)
        j += 1
      else
        return false
      end
    end
    while i < t_tokens.length
      return false unless optional_number_token?(t_tokens[i])
      i += 1
    end
    while j < tt_tokens.length
      return false unless optional_number_token?(tt_tokens[j])
      j += 1
    end
    !t_tokens.empty? && !tt_tokens.empty?
  end

  def self.optional_number_token?(token)
    return false if token.to_s.empty?
    token.match?(/\A\d+\z/) || %w[i ii iii iv v vi vii viii ix x xi xii xiii xiv xv xvi xvii xviii xix xx].include?(token.downcase)
  end

  def self.media_add(item_name, type, full_name, identifiers, attrs = {}, file_attrs = {}, file = {}, data = {})
    identifiers = [identifiers] unless identifiers.is_a?(Array)
    id = identifiers.join
    obj = {
      :full_name => full_name,
      :identifier => id,
      :identifiers => identifiers
    }
    data[id] = {
      :type => type,
      :name => item_name
    }.merge(obj).merge(attrs.deep_dup) if data[id].nil?
    data[id][:files] = [] if data[id][:files].nil?
    data[id][:files] << file.merge(obj).merge(file_attrs) unless file.nil? || file.empty? || !data[id][:files].select { |f| f[:name].to_s == file[:name].to_s }.empty?
    if attrs[:show]
      data[:shows] = {} if data[:shows].nil?
      data[:shows][item_name] = attrs[:show]
    end
    if attrs[:movie]
      data[:movies] = {} if data[:movies].nil?
      data[:movies][item_name] = attrs[:movie]
    end
    data
  end

  def self.media_exist?(files, identifiers, f_type = nil)
    !media_get(files, identifiers, f_type).empty?
  end

  def self.media_get(files, identifiers, f_type = nil)
    eps = {}
    identifiers = [identifiers.to_s] unless identifiers.is_a?(Array)
    identifiers.each do |i|
      eps.merge!(files.select do |id, f|
        id.to_s.include?(i) && (f_type.to_s == '' || f[:f_type].to_s == '' || f_type.to_s == f[:f_type].to_s)
      end)
    end
    eps
  end

  def self.media_chose(title, items, keys, category, no_prompt = 0)
    item = nil
    unless (items || []).empty?
      year = identify_release_year(title)
      items.sort_by! { |i| iyear = (i[keys['year']].to_i > 0 ? i[keys['year']].to_i : Time.now.year + 3); ((year.to_i > 0 ? year : iyear) - iyear).abs } if keys['year']
      items.map! { |i| i[keys['titles']].map { |t| ni = i.dup; ni[keys['name']] = t; ni } }.flatten! if keys['titles'].to_s != ''
      results = items.map { |m| { :title => m[keys['name']], :info => m[keys['url']] } }
      results += [{ :title => 'Edit title manually', :info => '' }]
      (0..results.count - 2).each do |i|
        show_year = items[i][keys['year']].to_i
        if match_titles(items[i][keys['name']], title, show_year, year, category)
          choice = i
        elsif no_prompt.to_i == 0
          MediaLibrarian.app.speaker.speak_up("Alternatives titles found for #{title}:")
          results.each_with_index do |m, idx|
            # Use URI.encode_www_form_component instead of the removed
            # URI.escape.  Convert nil values to strings to avoid errors.
            info_str = m[:info].to_s
            encoded_info = URI.encode_www_form_component(info_str)
            MediaLibrarian.app.speaker.speak_up("#{idx + 1}: #{m[:title]}#{' (info: ' + encoded_info + ')' if info_str != ''}")
          end
          choice = MediaLibrarian.app.speaker.ask_if_needed("Enter the number of the chosen title (empty to skip): ", no_prompt, 1).to_i - 1
        else
          choice = -1
        end
        next if choice < 0 || choice >= results.count
        if results[choice][:title] == 'Edit title manually'
          MediaLibrarian.app.speaker.speak_up('Enter the title to look for:')
          title = STDIN.gets.strip
          break
        end
        item = items[choice]
        title = item[keys['name']]
        break
      end
    end
    return title, item
  end

  def self.media_type_get(type)
    VALID_MEDIA_TYPES.select { |_, v| v.include?(Utils.regularise_media_type(type)) }.first[0]
  rescue => e
    MediaLibrarian.app.speaker.tell_error(e, Utils.arguments_dump(binding))
  end

  def self.missing_media_add(missing_eps, type, full_name, release_date, item_name, identifiers, info, display_name = nil)
    return missing_eps if full_name == ''
    MediaLibrarian.app.speaker.speak_up("Missing #{display_name || full_name} (ids '#{identifiers}') (released on #{release_date})", 0)
    missing_eps = Metadata.media_add(item_name,
                                     type,
                                     full_name,
                                     identifiers,
                                     info,
                                     {},
                                     {},
                                     missing_eps
    )
    missing_eps
  end

  def self.media_lookup(type, title, cache_category, keys, item_fetch_method, search_providers, no_prompt = 0, original_filename = '', ids = {}, force_refresh: 0)
    ids_part = ids.map { |k, v| k.to_s + v.to_s if v.to_s != '' }.join
    cache_name = [title, ids_part, original_filename].map(&:to_s).join('|')
    exact_title, item = title, nil
    cached = Cache.cache_get(cache_category, cache_name, 120, force_refresh)
    return cached if cached && cached[1] && force_refresh.to_i == 0
    Utils.lock_block("#{__method__}_#{type}_#{title}#{ids}") do
      exact_title, item = item_fetch_method.call(ids) unless ids.empty?
      search_providers.each do |o, m|
        break unless item.nil?
        begin

          title_norm = detect_real_title(title, type, 0, 0)
          provider_name = o.respond_to?(:name) ? o.name : o.class.name
          provider_call = "#{provider_name}##{m}"
          MediaLibrarian.app.speaker.speak_up("[#{provider_call}] -> '#{title_norm}'", 0) if Env.debug?
          items = nil
          Timeout.timeout(15) do
            meth = m.to_s.gsub(/_{2,}/, '_') # "search__movies" -> "search_movies"
            begin
              items = o.public_send(meth, title_norm)
            rescue NameError, NoMethodError
              # dernier recours: déléguer à method_missing si le provider l’implémente
              items = o.send(:method_missing, m, title_norm)
            end
          end
          raw_items = items
          raw_info = raw_items.nil? ? 'nil' : "#{raw_items.class}[#{raw_items.respond_to?(:size) ? raw_items.size : '?'}]"
          MediaLibrarian.app.speaker.speak_up("[#{provider_call}] <= raw #{raw_info}", 0) if Env.debug?
          if Env.debug? && raw_items
            Array(raw_items).each_with_index do |raw, idx|
              summary = raw.is_a?(Hash) ? (raw.dig('movie', 'title') || raw['title'] || raw['name']) : raw
              ids = raw.is_a?(Hash) ? (raw.dig('movie', 'ids') || raw['ids']) : nil
              MediaLibrarian.app.speaker.speak_up("[#{provider_call}] raw[#{idx}] #{summary.inspect} ids=#{ids.inspect}", 0)
            end
          end
          items = Array(items).compact
          items.map! do |m|
            v = if m.is_a?(Hash) && m['movie']
                  m['movie']
                else
                  Cache.object_pack(m, 1)
                end
            v = case type
                when 'movies'
                  v = v.is_a?(Hash) ? v : { 'name' => v.to_s }
                  detail_ids = v['ids'] || (v['id'] ? { 'tmdb' => v['id'] } : nil)
                  unless detail_ids
                    MediaLibrarian.app.speaker.tell_error(StandardError.new("[#{provider_call}] unexpected payload #{v.inspect}"), title_norm)
                    next nil
                  end
                  MediaLibrarian.app.speaker.speak_up("[#{provider_call}] detail fetch #{detail_ids}", 0) if Env.debug?
                  detail_item = item_fetch_method.call(detail_ids)
                  detail_item = detail_item && detail_item[1]
                  if detail_item.nil?
                    msg = "[#{provider_call}] detail lookup returned nil for ids #{detail_ids}"
                    Env.debug? ? MediaLibrarian.app.speaker.speak_up(msg, 0) : MediaLibrarian.app.speaker.tell_error(StandardError.new(msg), title_norm)
                    v['ids'] = detail_ids
                    v['name'] ||= v['title']
                    v['year'] ||= v['release_date'].to_s[0,4]
                    v
                  else
                    detail_item
                  end
                when 'shows'
                  TvSeries.new(v.merge({ 'ids' => v['ids'] || { 'thetvdb' => v['seriesid'], 'imdb' => v["imdb_id"] || v['IMDB_ID'] } }))
                end
            Cache.object_pack(v, 1) if v
          end
          items.compact!
          result_count = items.size
          summary = items.first
          summary = summary['title'] || summary['name'] if summary.respond_to?(:[])
          MediaLibrarian.app.speaker.speak_up("[#{provider_call}] => #{result_count} #{summary}", 0) if Env.debug?
          if result_count.zero?
            ids_info = ids_part.to_s == '' ? ids : ids_part
            msg = "Provider #{provider_call} returned no results title=#{title.inspect} normalized=#{title_norm.inspect} ids=#{ids_info} raw=#{raw_info}"
            msg << " file=#{original_filename}" if original_filename.to_s != ''
            MediaLibrarian.app.speaker.tell_error(StandardError.new(msg), "#{title_norm}")
          end
          exact_title, item = media_chose(title, items, keys, type, no_prompt.to_i)
          exact_title, item = item_fetch_method.call(item['ids'].merge({ 'force_title' => exact_title })) unless item.nil?
        rescue => e
          MediaLibrarian.app.speaker.tell_error e, "Metadata.media_lookup block"
        end
      end
      exact_title, item = Kodi.kodi_lookup(type, original_filename, exact_title) if item.nil? && original_filename.to_s != ''
      Cache.cache_add(cache_category, cache_name, [exact_title, item], item) if item
    end
    MediaLibrarian.app.speaker.speak_up("#{Utils.arguments_dump(binding)}= '#{exact_title}', nil", 0) if item.nil?
    return exact_title, item
  rescue => e
    MediaLibrarian.app.speaker.tell_error(e, Utils.arguments_dump(binding))
    return title, nil
  end

  def self.parse_media_filename(filename, type, item = nil, item_name = '', no_prompt = 0, folder_hierarchy = {}, base_folder = Dir.home, file = {})
    item_name, item = Metadata.identify_title(filename, type, no_prompt, (folder_hierarchy[type] || FOLDER_HIERARCHY[type]), base_folder) if item.nil? || item_name.to_s == ''
    full_name, ids, info, parts = '', [], {}, []
    return full_name, ids, info unless no_prompt.to_i == 0 || item
    case type
    when 'movies'
      release = item&.release_date ? item.release_date : Time.new(Metadata.identify_release_year(item_name))
      ids = [Movie.identifier(item_name, item.year)]
      full_name = item_name
      info = {
        :movies_name => item_name,
        :movie => item,
        :release_date => release,
        :titles => item.alt_titles
      }
      parts = Movie.identify_split_files(filename)
    when 'shows'
      e, _ = TvSeries.identify_tv_episodes_numbering(detect_real_title(filename, type, 1, 1))
      ids = e.map { |s, e| e.map { |n| TvSeries.identifier(item_name, n[:s], n[:ep]) } }.flatten
      ids = e.keys.map { |s| TvSeries.identifier(item_name, s, '') } if ids.empty?
      ids = [TvSeries.identifier(item_name, '', '')] if ids.empty?
      episode_numbering = e.map { |s, e| e.map { |n| "S#{format('%02d', s.to_i)}E#{format('%02d', n[:ep])}#{'.part' + n[:part].to_s if n[:part].to_i > 0}" } }.flatten.join(' ')
      f_type = TvSeries.identify_file_type(filename, e)
      full_name = "#{item_name}"
      if f_type != 'series' && full_name != ''
        full_name << " #{f_type == 'season' ? e.keys.map { |s| 'S' + format('%02d', s.to_i) }.join : episode_numbering}"
      end
      parts = e.values.flatten.map { |ep| ep[:part].to_i }.select { |ep| ep > 0 }
      info = {
        :series_name => item_name,
        :episode_season => e.keys.map { |s| s.to_i }.join(' '),
        :episode => e.values.flatten,
        :episode_numbering => episode_numbering,
        :show => item,
        :f_type => f_type
      }
    end
    info[:language] = item.language if item.class.method_defined?("language")
    file[:parts] = parts unless file.nil? || file.empty?
    return full_name, ids, info
  end
end
