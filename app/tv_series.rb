class TvSeries

  def self.handle_duplicates_tv(files, series_name, remove_duplicates = 0, no_prompt = 0)
    dups = []
    files.each do |s, eps|
      next if s == :name
      eps.each do |_, parts|
        parts.each do |_, f|
          grouped = f.group_by { |ep| ep[:episode] }
          dups += grouped.values.select { |a| a.size > 1 }.flatten
        end
      end
    end
    consolidated = dups.map { |e| [e[:season], e[:episode], e[:part]] }.uniq
    unless consolidated.empty?
      consolidated.each do |d|
        $speaker.speak_up("Duplicate episodes found for #{series_name} S#{format('%02d', d[0].to_i)}E#{format('%02d', d[1].to_i)}:")
        dups_files = MediaInfo.sort_media_files(MediaInfo.series_get_ep(files, series_name, d[0], d[1], d[2]))
        dups_files.each do |f|
          $speaker.speak_up("'#{f[:file]}'")
        end
        if remove_duplicates.to_i > 0
          $speaker.speak_up('Will now remove duplicates:')
          dups_files.each do |f|
            next if dups_files.index(f) == 0 && no_prompt.to_i > 0
            Utils.file_rm(f[:file]) if $speaker.ask_if_needed("Remove file #{f[:file]}? (y/n)", no_prompt.to_i, 'y').to_s == 'y'
          end
        end
      end
    end
  end

  def self.look_for_duplicates(folder, series_name, no_prompt, remove_duplicates = 0)
    episodes_in_files= {}
    Utils.search_folder(folder, {'regex' => VALID_VIDEO_EXT}).each do |ep|
      s, e = MediaInfo.identify_tv_episodes_numbering(File.basename(ep[0]))
      e.each do |n|
        episodes_in_files = MediaInfo.series_add(series_name, s, n[:ep], n[:part], ep[0], episodes_in_files)
      end
    end
    handle_duplicates_tv(episodes_in_files, series_name, remove_duplicates, no_prompt)
    episodes_in_files
  end

  def self.monitor_tv_episodes(folder:, no_prompt: 0, delta: 10, include_specials: 0, remove_duplicates: 0, handle_missing: {}, only_series_name: '')
    handle_missing = eval(handle_missing) if handle_missing.is_a?(String)
    query = {'maxdepth' => 1, 'includedir' => 1}
    query.merge!({'regex' => '^' + Utils.regexify(only_series_name, 1).gsub(/[\(\)]/, '.+') + '$'}) if only_series_name.to_s != ''
    Utils.search_folder(folder, query).each do |series|
      next unless File.directory?(series[0])
      begin
        series_name = File.basename(series[0])
        episodes_in_files = look_for_duplicates(series[0], series_name, no_prompt, remove_duplicates)
        _, @tv_episodes[series_name] = MediaInfo.tv_episodes_search(series_name, no_prompt)
        @tv_episodes[series_name].each do |ep|
          next unless (ep.air_date.to_s != '' && ep.air_date < Time.now - delta.days) || MediaInfo.series_exist?(episodes_in_files, series_name, ep.season_number.to_i, ep.number.to_i + 1)
          next if include_specials.to_i == 0 && ep.season_number.to_i == 0
          unless MediaInfo.series_exist?(episodes_in_files, series_name, ep.season_number.to_i, ep.number.to_i)
            $speaker.speak_up("Missing #{series_name} S#{format('%02d', ep.season_number.to_i)}E#{format('%02d', ep.number.to_i)} - #{ep.name} (aired on #{ep.air_date}). Look for it:")
            if handle_missing['download'].to_i > 0
              if Utils.entry_deja_vu?(__method__.to_s, "#{series_name}S#{format('%02d', ep.season_number.to_i)}E#{format('%02d', ep.number.to_i)}")
                $speaker.speak_up('Entry already downloaded')
              else
                success = TorrentSearch.search(keywords: series_name.gsub(/[\(\)\:]/, '') + " S#{format('%02d', ep.season_number.to_i)}E#{format('%02d', ep.number.to_i)}",
                                               limit: 50,
                                               category: 'tv',
                                               no_prompt: no_prompt,
                                               filter_dead: 1,
                                               move_completed: handle_missing['move_to'],
                                               main_only: handle_missing['main_only'],
                                               only_on_trackers: handle_missing['only_on_trackers'],
                                               qualities: handle_missing['quality'])
                success = TorrentSearch.search(keywords: series_name.gsub(/[\(\)\:]/, '') + " S#{format('%02d', ep.season_number.to_i)}",
                                               limit: 50,
                                               category: 'tv',
                                               no_prompt: no_prompt,
                                               filter_dead: 1,
                                               move_completed: handle_missing['move_to'],
                                               main_only: handle_missing['main_only'],
                                               only_on_trackers: handle_missing['only_on_trackers'],
                                               qualities: handle_missing['quality']) unless success || no_prompt.to_i > 0
                Utils.entry_seen(__method__.to_s, "#{series_name}S#{format('%02d', ep.season_number.to_i)}E#{format('%02d', ep.number.to_i)}") if success
              end
            end
          end
        end
      rescue => e
        $speaker.tell_error(e, "Monitor tv series block #{series_name}")
      end
    end
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