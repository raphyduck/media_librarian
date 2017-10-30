class TvSeries

  @tv_episodes = {}

  def self.identifier(series_name, season, episode, part)
    "#{series_name}S#{season.to_i}E#{episode.to_i}P#{part.to_i}"
  end

  def self.monitor_tv_episodes(folder:, no_prompt: 0, delta: 10, include_specials: 0, remove_duplicates: 0, handle_missing: {}, only_series_name: '')
    handle_missing = eval(handle_missing) if handle_missing.is_a?(String)
    query = {'maxdepth' => 1, 'includedir' => 1}
    query.merge!({'regex' => '^' + Utils.regexify(only_series_name, 1).gsub(/[\(\)]/, '.+') + '$'}) if only_series_name.to_s != ''
    episodes_in_files, item_folders = Library.process_folder(type: 'tv', folder: folder, item_name: only_series_name, remove_duplicates: remove_duplicates, no_prompt: no_prompt)
    missing_eps = {}
    Utils.search_folder(folder, query).each do |series|
      next unless File.directory?(series[0])
      begin
        series_name = File.basename(series[0])
        _, @tv_episodes[series_name] = MediaInfo.tv_episodes_search(series_name, no_prompt)
        @tv_episodes[series_name].each do |ep|
          next unless (ep.air_date.to_s != '' && ep.air_date < Time.now - delta.days) || MediaInfo.media_exist?(episodes_in_files, identifier(series_name, ep.season_number, ep.number.to_i + 1, nil))
          next if include_specials.to_i == 0 && ep.season_number.to_i == 0
          unless MediaInfo.media_exist?(episodes_in_files, identifier(series_name, ep.season_number, ep.number.to_i, nil))
            full_name = "#{series_name} S#{format('%02d', ep.season_number.to_i)}E#{format('%02d', ep.number.to_i)}"
            $speaker.speak_up("Missing #{full_name} - #{ep.name} (aired on #{ep.air_date}).")
            if Utils.entry_deja_vu?('download', identifier(series_name, ep.season_number, ep.number, 0))
              $speaker.speak_up('Entry already downloaded', 0)
            else
              missing_eps = MediaInfo.media_add(series_name,
                                                'tv',
                                                full_name,
                                                identifier(series_name, ep.season_number, ep.number, 0),
                                                {:season => ep.season_number.to_i, :episode => ep.number.to_i, :part => 0},
                                                '',
                                                missing_eps
              )
            end
          end
        end
      rescue => e
        $speaker.tell_error(e, "Monitor tv series block #{series_name}")
      end
    end
    Library.search_from_list(list: missing_eps, no_prompt: no_prompt, torrent_search: handle_missing) if handle_missing['download'].to_i > 0
  end

  def self.rename_tv_series(folder:, search_tvdb: 1, no_prompt: 0, skip_if_not_found: 1)
    Utils.search_folder(folder, {'maxdepth' => 1, 'includedir' => 1}).each do |series|
      next unless File.directory?(series[0])
      begin
        series_name = File.basename(series[0])
        _, @tv_episodes[series_name] = MediaInfo.tv_episodes_search(series_name, no_prompt) if search_tvdb.to_i > 0 && @tv_episodes[series_name].nil?
        next if @tv_episodes[series_name].empty? && skip_if_not_found.to_i > 0
        Utils.search_folder(series[0], {'regex' => VALID_VIDEO_EXT}).each do |ep|
          ep_filename = File.basename(ep[0])
          season, ep_nb = MediaInfo.identify_tv_episodes_numbering(ep_filename)
          if season == '' || ep_nb.empty?
            season = $speaker.ask_if_needed("Season number not recognized for #{ep_filename}, please enter the season number now (empty to skip)", no_prompt, '').to_i
            ep_nb = [{:ep => $speaker.ask_if_needed("Episode number not recognized for #{ep_filename}, please enter the episode number now (empty to skip)", no_prompt, '').to_i, :part => 0}]
          end
          destination = "#{folder}/{{ series_name }}/Season {{ episode_season }}/{{ series_name|titleize|nospace }}.{{ episode_numbering|nospace }}.{{ episode_name|titleize|nospace }}.{{ quality|downcase|nospace }}.{{ proper|downcase }}"
          rename_tv_series_file(ep[0], series_name, season, ep_nb, destination)
        end
      rescue => e
        $speaker.tell_error(e, "Rename tv series block #{series_name}")
      end
    end
  end

  def self.rename_tv_series_file(original, series_name, episode_season, episodes_nbs, destination, quality = nil, hard_link = 0, replaced_outdated = 0)
    _, @tv_episodes[series_name] = MediaInfo.tv_episodes_search(series_name, 1) if @tv_episodes[series_name].nil?
    quality = quality || File.basename(original).downcase.gsub('-', '').scan(REGEX_QUALITIES).join('.').gsub('-', '')
    proper, _ = MediaInfo.identify_proper(original)
    episode_name = []
    episode_numbering = []
    episodes_nbs.each do |n|
      tvdb_ep = !@tv_episodes[series_name].empty? && episode_season != '' && n[:ep].to_i > 0 ? @tv_episodes[series_name].select { |e| e.season_number == episode_season.to_i.to_s && e.number == n[:ep].to_s }.first : nil
      episode_name << (tvdb_ep.nil? ? '' : tvdb_ep.name.to_s.downcase)
      if n[:ep].to_i > 0 && episode_season != ''
        episode_numbering << "S#{format('%02d', episode_season.to_i)}E#{format('%02d', n[:ep])}#{'.' + n[:part].to_s if n[:part].to_i > 0}."
      end
    end
    episode_name = episode_name.join(' ')[0..50]
    extension = original.gsub(/.*\.(\w{2,4}$)/, '\1')
    episode_numbering = episode_numbering.join(' ')
    FILENAME_NAMING_TEMPLATE.each do |k|
      destination = destination.gsub(Regexp.new('\{\{ ' + k + '((\|[a-z]*)+)? \}\}')) { Utils.regularise_media_filename(eval(k), $1) }
    end
    destination += ".#{extension.downcase}"
    if episode_numbering != ''
      _, destination = Utils.move_file(original, destination, hard_link, replaced_outdated)
    else
      destination = ''
    end
    destination
  end
end