class TvSeries

  def self.identifier(series_name, season, episode, part)
    "#{series_name}S#{season.to_i}E#{episode.to_i}P#{part.to_i}"
  end

  def self.monitor_tv_episodes(episodes_in_files, no_prompt = 0, delta = 10, include_specials = 0, handle_missing = {})
    missing_eps, tv_episodes = {}, {}
    return if episodes_in_files[:shows].nil?
    episodes_in_files[:shows].each do |series_name, show|
      _, tv_episodes[series_name] = MediaInfo.tv_episodes_search(series_name, no_prompt, show)
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
      Library.search_from_list(list: missing_eps, no_prompt: no_prompt, torrent_search: handle_missing) if !handle_missing.nil? && !handle_missing.empty?
    end
  rescue => e
    $speaker.tell_error(e, "TvSeries.monitor_tv_episodes")
  end
end