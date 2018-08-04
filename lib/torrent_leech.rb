require File.dirname(__FILE__) + '/torrent_site'
module TorrentLeech
  class Search < TorrentSite::Search

    attr_accessor :url

    def initialize(search, url = nil, cid = '')
      @base_url = 'https://www.torrentleech.org'
      # Order by seeds desc
      @query = search
      @url = url || "#{@base_url}/torrents/browse/index#{'/categories/' + cid.to_s if cid.to_s != ''}/query/#{URI.escape(search.gsub(/\ \ +/, ' '))}#{'/orderby/seeders/order/desc' if search.to_s != ''}" #/torrents/browse/index/categories/11,37,43,14,12,13,26,32,27/query/batman/orderby/seeders/order/desc
      @css_path = 'table.torrents tbody tr'
      post_init
    end

    private

    def auth
      $tracker_client[@base_url].get_url(@base_url + '/')
      $tracker_client[@base_url].fill_in('username', with: $config[tracker]['username'], wait: 30)
      $tracker_client[@base_url].fill_in('password', with: $config[tracker]['password'], wait: 30)
      $tracker_client[@base_url].click_button('Log in')
    end

    def crawl_link(link)
      cols = link.all('td')
      raw_size = cols[5].text.to_s
      size = raw_size.match(/[\d\.]+/).to_s.to_d
      s_unit = raw_size.gsub(/[\d\. ]+/, '').to_s.strip
      size = size_unit_convert(size, s_unit)
      {
          :name => cols[1].all('a')[0].text.to_s.force_encoding('utf-8'),
          :size => size,
          :link => cols[1].all('a')[0]['href'],
          :torrent_link => cols[2].find_link(:visible => :visible)['href'],
          :magnet_link => '',
          :seeders => cols[7].text.to_i,
          :leechers => cols[8].text.to_i,
          :id => link['data-tid'].to_i,
          :added => cols[3].text.to_s,
          :tracker => tracker
      }
    end
  end
end
