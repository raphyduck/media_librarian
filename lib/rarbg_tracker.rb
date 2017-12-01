require File.dirname(__FILE__) + '/torrent_site'
module RarbgTracker
  class Search < TorrentSite::Search

    attr_accessor :url

    def initialize(search, cid = '', search_type = 'str')
      @base_url = 'https://rarbg.to'
      @query = search
      @cat = cid
      @s_type = search_type
      $tracker_client[@base_url] = RARBG::API.new
    end

    def download(url, destination, name)
      $speaker.speak_up('Rarbg do not provide torrent link')
      ''
    end

    private

    def crawl_link(link)
      {
          :name => link['title'].to_s.force_encoding('utf-8'),
          :size => link['size'],
          :link => link['info_page'],
          :magnet_link => link['download'],
          :seeders => link['seeders'],
          :leechers => link['leechers'],
          :id => Time.now.to_i,
          :added => link['pubdate'],
          :tracker => tracker
      }
    end

    def get_rows
      req = {}
      req.merge({'category' => @cat}) if @cat != ''
      case @s_type
        when 'str'
          @links ||= $tracker_client[@base_url].search_string(@query, req)
        when 'imdb'
          @links ||= $tracker_client[@base_url].search_imdb(@query, req)
        when 'themoviedb'
          @links ||= $tracker_client[@base_url].search_themoviedb(@query, req)
        when 'tvdb'
          @links ||= $tracker_client[@base_url].search_tvdb(@query, req)
      end
    end
  end
end
