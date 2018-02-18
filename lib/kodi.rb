class Kodi

  @kodi_media = {}

  def self.get_media(type, properties = ['title', 'lastplayed', 'playcount', 'imdbnumber'])
    @kodi_media[type] = Vash.new if @kodi_media[type].nil?
    cache_name = properties.map{|x| x[0..2]}.join
    return @kodi_media[type][cache_name] if @kodi_media[type][cache_name]
    if $kodi.to_i > 0
      case type
        when 'movies'
          @kodi_media[type][cache_name, CACHING_TTL] = Xbmc::VideoLibrary.get_movies({:properties => properties, :sort => {:order => 'ascending', :method => 'label'}})
        when 'shows'
          @kodi_media[type][cache_name, CACHING_TTL] = Xbmc::VideoLibrary.get_tv_shows({:properties => properties, :sort => {:order => 'ascending', :method => 'label'}})
        when 'episode'
          @kodi_media[type][cache_name, CACHING_TTL] = Xbmc::VideoLibrary.get_episodes({:properties => properties, :sort => {:order => 'ascending', :method => 'label'}})
      end
    end
    @kodi_media[type][cache_name]
  end

  def self.kodi_lookup(type, filename, title)
    exact_title, item = title, nil
    properties = case type
                   when 'movies'
                     ['title', 'year', 'file', 'imdbnumber']
                   when  'episode'
                     ['showtitle', 'file']
    end
    get_media(type, properties).each do |i|
      if i['file'].include?(filename)
        case type
          when 'movies'
            exact_title, item = Movie.movie_get(i['imdbnumber'])
          when 'episodes'
            show = nil
            get_media('shows', ['title', 'imdbnumber']).each do |s|
              if s['title'] == i['showtitle']
                show = s
                break
              end
            end
            exact_title, item = MediaInfo.tv_show_get(show['imdbnumber']) if show
        end
        break
      end
    end
    return exact_title, item
  end
end