require File.dirname(__FILE__) + '/torrent_site'
module Wop
  ##
  # Extract a list of results from your search
  class Search < TorrentSite::Search

    attr_accessor :url

    def initialize(search, url = nil)
      @base_url = 'https://worldofp2p.net'
      # Order by seeds desc
      #@url = "#{@base_url}/engine/search?q=the+circle+2017"
      @query = search
      @url = url || "#{@base_url}/browse.php?search=#{URI.escape(search)}&searchin=title&incldead=0" #/browse.php?search=test&searchin=title&incldead=0
      if @client.nil?
        @client = Mechanize.new
        @client.pluggable_parser['application/x-bittorrent'] = Mechanize::Download
        @client_logged = false
      end
    end

    private

    def authenticate!
      if $config['worldofp2p']
        $speaker.speak_up('Authenticating on WorldofP2P.')
        login = @client.get(@base_url + '/login.php?returnto=%2Findex.php')
        login_form = login.forms[0]
        login_form.username = $config['worldofp2p']['username']
        login_form.password = $config['worldofp2p']['password']
        @client.submit login_form
        @client_logged = true
      else
        $speaker.speak_up('WorldofP2P not configured, cannot authenticate')
      end
    end

    def crawl_link(link)
      cols = link.xpath('.//td')
      links = cols[1].xpath('.//a')
      tlink = cols[2].xpath('.//a')[0]['href']
      raw_size = cols[7].to_s
      size = raw_size.match(/[\d\.]+/).to_s.to_d
      s_unit = raw_size.gsub(/<td [\w=\"]*>[\d\.]+<br>/, '').gsub('</td>', '').to_s
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
          'link' => @base_url + '/' + links[0]['href'],
          'torrent_link' => @base_url + '/' + tlink,
          'magnet_link' => '',
          'seeders' => cols[9].text.to_i,
          'leechers' => cols[10].text.to_i,
          'id' => links[0]['href'].gsub(/[\w\.]*\?id=(\d+)&.*/, '\1').to_s,
          'added' => cols[6].text.gsub(/\n/, ''),
      }
    end

    def get_rows
      page.xpath('//table[@class="yenitorrenttable"]/tr[@class="browse_color"]')[0..50] || []
    end
  end
end
