require 'torznab/client'

class TorznabTracker
  DOWNLOAD_URL_PATTERN = %r{/(?:download|dl)/}i

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
      link = i[:link]
      download_fallback = guid.to_s.empty? ? link : guid
      download_url = enclosure_url.to_s.empty? ? download_fallback : enclosure_url
      details_url = link.to_s.empty? ? guid : link
      comments_url = i[:comments]
      if comments_url && !comments_url.to_s.empty? && details_url.to_s.match?(DOWNLOAD_URL_PATTERN)
        details_url = comments_url
      end
      attrs = Array(i[:attr]).each_with_object({}) do |attr, memo|
        next unless attr.respond_to?(:[])
        name = attr[:name] || attr['name']
        next unless name
        memo[name.to_s] = attr[:value] || attr['value']
      end
      result << {
          :name => i[:title],
          :size => i[:size],
          :link => download_url,
          :torrent_link => details_url,
          :magnet_link => '',
          :seeders => attrs['seeders'],
          :leechers => attrs['leechers'],
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
