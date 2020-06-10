require File.dirname(__FILE__) + '/torrent_site'
module Yggtorrent
  class Search < TorrentSite::Search

    attr_accessor :url

    def initialize(search, url = nil, cid = '')
      @base_url = TORRENT_TRACKERS['yggtorrent'][0] #'https://ygg.to/'
      # Order by seeds desc
      @query = search
      @url = url || "#{@base_url}/engine/search?#{cid}name=#{URI.escape(search)}&do=search#{'&order=desc&sort=seed' if search.to_s != ''}"
      @css_path = 'table.table tbody tr'
      @logged_in_css = 'a#panel-btn'
      post_init
    end

    private

    def auth
      $tracker_client[@base_url].find('a#register').click
      $tracker_client[@base_url].fill_in('id', with: $config[tracker]['username'], wait: 30)
      $tracker_client[@base_url].fill_in('pass', with: $config[tracker]['password'], wait: 30)
      $tracker_client[@base_url].find_button("Connexion").trigger('click')
    end

    def crawl_link(link)
      cols = link.all('td')
      links = cols[1].all('a')
      tlink = links[0]['href']
      t = $tracker_client[@base_url].get(tlink)
      t.css('a').each do |anchor|
        if anchor.attribute('href') && anchor.attribute('href').value.include?('download_torrent')
          tlink = anchor['href']
          break
        end
      end
      raw_size = cols[5] ? cols[5].text.to_s : 0
      size = raw_size.match(/[\d\.]+/).to_s.to_d
      s_unit = raw_size.gsub(/[\d\.]+/, '').to_s.strip
      size = size_unit_convert(size, s_unit)
      {
          :name => links[0].text.to_s.force_encoding('utf-8').gsub("\r\n", ""),
          :size => size,
          :link => links[0]['href'],
          :torrent_link => tlink,
          :magnet_link => '',
          :seeders => cols[7].text.to_i,
          :leechers => cols[8].text.to_i,
          :id => links[0].text.gsub(/\/torrent\/(\d+)\/.*/, '\1').to_s.gsub("\r\n", ""),
          :added => DateTime.strptime(cols[4].find('div', visible: false).text(:all), '%s'),
          :tracker => tracker
      }
    end
  end
end
