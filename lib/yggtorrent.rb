require File.dirname(__FILE__) + '/torrent_site'
module Yggtorrent
  class Download < TorrentSite::Download
  end
  ##
  # Extract a list of results from your search
  class Search < TorrentSite::Search
    BASE_URL = 'https://yggtorrent.com'.freeze

    attr_accessor :url

    def initialize(search, url = nil)
      # Order by seeds desc
      #@url = "#{BASE_URL}/engine/search?q=the+circle+2017"
      @query = search
      @url = url || "#{BASE_URL}/engine/search?q=#{URI.escape(search)}"
      if $ygg_agent.nil?
        $ygg_agent = Mechanize.new
        $ygg_agent.pluggable_parser['application/x-bittorrent'] = Mechanize::Download
        $ygg_logged = false
      end
    end

    def download(url, destination, name)
      authenticate! unless $ygg_logged
      return unless $ygg_logged
      $ygg_agent.get(url).save("#{destination}/#{name}.torrent")
    end

    private

    def authenticate!
      if $config['yggtorrent']
        Speaker.speak_up('Authenticating on yggtorrent.')
        login = $ygg_agent.get(BASE_URL + '/user/login')
        login_form = login.forms[1]
        login_form.id = $config['yggtorrent']['username']
        login_form.pass = $config['yggtorrent']['password']
        $ygg_agent.submit login_form
        $ygg_logged = true
      else
        Speaker.speak_up('YggTorrent not configured, cannot authenticate')
      end
    end

    def page
      @page ||= $ygg_agent.get(@url)
    end

    def crawl_link(link)
      cols = link.xpath('.//td')
      links = cols[0].xpath('.//a')
      tlink = links[1]['href']
      tlink = links[2]['href'] if !tlink.match('download_torrent')
      raw_size = cols[3].to_s
      size = raw_size.match(/[\d\.]+/).to_s.to_d
      s_unit = raw_size.gsub(/<td>[\d\.]+/,'').gsub('</td>','').to_s
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
          'link' => links[0]['href'],
          'torrent_link' => tlink,
          'magnet_link' => '',
          'seeders' => cols[4].text.to_i,
          'leechers' => cols[5].text.to_i,
          'id' => links[0].text.gsub(/\/torrent\/(\d+)\/.*/,'\1').to_s,
          'added' => cols[2].text.gsub(/\n/,''),
      }
    end

    def get_rows
      page.xpath('.//table/tbody/tr')[0..50] || []
    end
  end
end
