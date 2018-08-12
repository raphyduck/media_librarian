require File.dirname(__FILE__) + '/torrent_site'
module Wop
  class Search < TorrentSite::Search

    attr_accessor :url

    def initialize(search, url = nil, cid = '')
      @base_url = TORRENT_TRACKERS['wop'] #'https://worldofp2p.net'
      # Order by seeds desc
      #@url = "#{@base_url}/engine/search?q=the+circle+2017"
      @query = search
      @url = url || "#{@base_url}/browse.php?#{cid}search=#{URI.escape(search)}&searchin=title&incldead=0" #/browse.php?search=test&searchin=title&incldead=0
      @css_path = 'table.yenitorrenttable tr.browse_color'
      post_init
    end

    private

    def auth
      $tracker_client[@base_url].get_url(@base_url + '/login.php?returnto=%2Findex.php')
      $tracker_client[@base_url].fill_in('username', with: $config[tracker]['username'], wait: 30)
      $tracker_client[@base_url].fill_in('password', with: $config[tracker]['password'], wait: 30)
      $tracker_client[@base_url].click_button('Log in!')
    end

    def crawl_link(link)
      cols = link.all('td')
      links = cols[1].all('a')
      name = links[0].text
      tlink = cols[2].all('a')[0]['href']
      raw_size = cols[7].text.to_s
      size = raw_size.match(/[\d\.]+/).to_s.to_d
      s_unit = raw_size.gsub(/[\d\.]+<br>/, '').gsub('</td>', '').to_s.strip
      size = size_unit_convert(size, s_unit)
      {
          :name => name.to_s.force_encoding('utf-8'),
          :size => size,
          :link => @base_url + '/' + links[0]['href'],
          :torrent_link => @base_url + '/' + tlink,
          :magnet_link => '',
          :seeders => cols[9].text.to_i,
          :leechers => cols[10].text.to_i,
          :id => links[0]['href'].gsub(/[\w\.]*\?id=(\d+)&.*/, '\1').to_s,
          :added => cols[6].text.gsub(/\n/, ''),
          :tracker => tracker
      }
    end
  end
end
