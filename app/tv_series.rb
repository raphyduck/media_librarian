class TvSeries

  def self.identifier(series_name, season, episode, part)
    "#{series_name}S#{season.to_i}E#{episode.to_i}P#{part.to_i}"
  end

  def self.monitor_tv_episodes(folder:, no_prompt: 0, delta: 10, include_specials: 0, remove_duplicates: 0, handle_missing: {}, only_series_name: '')
    query = {'maxdepth' => 1, 'includedir' => 1}
    query.merge!({'regex' => '^' + Utils.regexify(only_series_name, 1).gsub(/[\(\)]/, '.+') + '$'}) if only_series_name.to_s != ''
    episodes_in_files = Library.process_folder(type: 'shows', folder: folder, item_name: only_series_name, remove_duplicates: remove_duplicates, no_prompt: no_prompt)
    missing_eps, tv_episodes = {}, {}
    Utils.search_folder(folder, query).each do |series|
      next unless File.directory?(series[0])
      begin
        series_name = File.basename(series[0])
        series = episodes_in_files[:shows] && episodes_in_files[:shows][series_name] ? episodes_in_files[:shows][series_name] : nil
        _, tv_episodes[series_name] = MediaInfo.tv_episodes_search(series_name, no_prompt, series)
        tv_episodes[series_name].each do |ep|
          next unless (ep.air_date.to_s != '' && ep.air_date < Time.now - delta.days) || MediaInfo.media_exist?(episodes_in_files, identifier(series_name, ep.season_number, ep.number.to_i + 1, nil))
          next if include_specials.to_i == 0 && ep.season_number.to_i == 0
          unless MediaInfo.media_exist?(episodes_in_files, identifier(series_name, ep.season_number, ep.number.to_i, nil))
            full_name = "#{series_name} S#{format('%02d', ep.season_number.to_i)}E#{format('%02d', ep.number.to_i)}"
            $speaker.speak_up("Missing #{full_name} - #{ep.name} (aired on #{ep.air_date}).")
            if Utils.entry_deja_vu?('download', identifier(series_name, ep.season_number, ep.number, 0))
              $speaker.speak_up('Entry already downloaded', 0)
            else
              missing_eps = MediaInfo.media_add(series_name,
                                                'shows',
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
end