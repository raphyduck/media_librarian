require File.dirname(__FILE__) + '/torrent_site'
module Wop
  class Download < TorrentSite::Download
  end
  ##
  # Extract a list of results from your search
  class Search < TorrentSite::Search
    BASE_URL = 'https://worldofp2p.net'.freeze

    attr_accessor :url

    def initialize(search, url = nil)
      # Order by seeds desc
      #@url = "#{BASE_URL}/engine/search?q=the+circle+2017"
      @query = search
      @url = url || "#{BASE_URL}/browse.php?search=#{URI.escape(search)}&searchin=title&incldead=0" #/browse.php?search=test&searchin=title&incldead=0
      if $wop.nil?
        $wop = Mechanize.new
        $wop.pluggable_parser['application/x-bittorrent'] = Mechanize::Download
        $wop_logged = false
      end
    end

    def download(url, destination, name)
      authenticate! unless $wop_logged
      return unless $wop_logged
      $wop.get(url).save("#{destination}/#{name}.torrent")
    end

    private

    def authenticate!
      if $config['worldofp2p']
        $speaker.speak_up('Authenticating on WorldofP2P.')
        login = $wop.get(BASE_URL + '/login.php?returnto=%2Findex.php')
        login_form = login.forms[0]
        login_form.username = $config['worldofp2p']['username']
        login_form.password = $config['worldofp2p']['password']
        $wop.submit login_form
        $wop_logged = true
      else
        $speaker.speak_up('WorldofP2P not configured, cannot authenticate')
      end
    end

    def page
      authenticate! unless $wop_logged
      @page ||= $wop.get(@url)
    end

    def crawl_link(link)
      cols = link.xpath('.//td')
      links = cols[1].xpath('.//a')
      tlink = cols[2].xpath('.//a')[0]['href']
      raw_size = cols[7].to_s
      size = raw_size.match(/[\d\.]+/).to_s.to_d
      s_unit = raw_size.gsub(/<td [\w=\"]*>[\d\.]+<br>/,'').gsub('</td>','').to_s
      case s_unit
        when 'MB'
          size *= 1024 * 1024
        when 'GB'
          size *= 1024 * 1024 * 1024
        when 'TB'
          size *= 1024 * 1024 * 1024 * 1024
      end
      {
          'name' => links[0].text,
          'size' => size,
          'link' => BASE_URL + '/' + links[0]['href'],
          'torrent_link' => BASE_URL + '/' + tlink,
          'magnet_link' => '',
          'seeders' => cols[9].text.to_i,
          'leechers' => cols[10].text.to_i,
          'id' => links[0]['href'].gsub(/[\w\.]*\?id=(\d+)&.*/,'\1').to_s,
          'added' => cols[6].text.gsub(/\n/,''),
      }
    end

    def get_rows
        page.xpath('//table[@class="yenitorrenttable"]/tr[@class="browse_color"]')[0..50] || []
      #page.css('tr.browse_color')[0..50] || []
    end
  end
end
