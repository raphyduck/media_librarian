require File.dirname(__FILE__) + '/torrent_site'
module RarbgTracker
  class Search < TorrentSite::Search

    attr_accessor :url

    def initialize(search, cid = '')
      @base_url = TORRENT_TRACKERS['rarbg'][0]
      @query = search
      @cat = cid
      @cat = [] if cid.to_s == ''
      @url = @base_url + "/torrents.php?search=#{search}#{([''] + @cat).join('&category[]=') unless @cat.empty?}" #/torrents.php?search=batman
      @css_path = 'table.lista2t tr.lista2'
      post_init
    end

    private

    def crawl_link(link)
      cols = link.all('td')
      links = cols[1].all('a')
      raw_size = cols[3].text.to_s
      size = raw_size.match(/[\d\.]+/).to_s.to_d
      s_unit = raw_size.gsub(/[\d\.]+ /,'').to_s.strip
      size = size_unit_convert(size, s_unit)
      id = links[0]['href'].gsub(/(#{@base_url})?\/torrent\//, '')
      {
          :name => links[0].text.to_s,
          :size => size,
          :link => @base_url + "/torrent/#{id}",
          :torrent_link => "#{@base_url}/download.php?id=#{id}&f=#{links[0].text.to_s}-[rarbg.to].torrent",
          #:magnet_link => link['download'], #Would require to visit the torrent page to get this url, not worth it
          :seeders => cols[4].text.to_s,
          :leechers => cols[5].text.to_s,
          :id => id,
          :added => cols[2].text.to_s,
          :tracker => tracker
      }
    end
  end
end