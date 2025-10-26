require 'torznab/client'

class TorznabTracker
  attr_accessor :config, :tracker, :name, :limit

  def initialize(opts, name)
    @tracker = Torznab::Client.new(opts['api_url'], opts['api_key'])
    @config = opts
    @name = name
    @limit = (opts['limit'] || 50).to_i
  end

  def search(type, query)
    result = []
    return result unless @tracker.caps.search_modes.search.available
    t, cat = 'search', []
    if type.to_s == 'movies' && @tracker.caps.search_modes.movie_search.available
      t = 'movie'
      cat = @tracker.caps.categories.select { |c| c.name.downcase.include?('movie') || c.name.downcase.include?('film') }.map { |c| c.id }
    elsif type.to_s == 'shows' && @tracker.caps.search_modes.tv_search.available
      t = 'tvsearch'
      cat = @tracker.caps.categories.select { |c| c.name.downcase.include?('tv') }.map { |c| c.id }
    end
    MediaLibrarian.app.speaker.speak_up "Running search on tracker '#{name}' for query '#{query}' for category '#{type}' (#{cat.join(',')})" if Env.debug?
    Hash.from_xml(@tracker.get({'t' => t, 'cat' => cat.join(','), 'q' => query, 'limit' => limit}))[:rss][:channel][:item].each do |i|
      enclosure_url = i.dig(:enclosure, :@url) || i.dig(:enclosure, :url)
      guid = if i[:guid].is_a?(Hash)
        guid_hash = i[:guid]
        [:__content__, :content, :text, '__content__', 'content', 'text']
          .lazy
          .map { |key| guid_hash[key] }
          .find { |value| !value.to_s.empty? }
      else
        i[:guid]
      end
      download_fallback = guid.to_s.empty? ? i[:link] : guid
      download_url = enclosure_url.to_s.empty? ? download_fallback : enclosure_url
      details_url = i[:link].to_s.empty? ? download_fallback : i[:link]
      result << {
          :name => i[:title],
          :size => i[:size],
          :link => details_url,
          :torrent_link => download_url,
          :magnet_link => '',
          :seeders => i[:attr].select{|t| t[:name] == 'seeders'}.first[:value],
          :leechers => i[:attr].select{|t| t[:name] == 'seeders'}.first[:seeders],
          :id => (Time.now.to_f * 1000).to_i.to_s,
          :added => i[:pubDate],
          :tracker => name
      }
    end
    result
  rescue => e
    MediaLibrarian.app.speaker.tell_error(e, Utils.arguments_dump(binding))
    []
  end

end