require File.dirname(__FILE__) + '/torrent_site'
module Yggtorrent
  class Download < TorrentSite::Download
    def self.download(url, destination, name)
      authenticate unless @logged
      return unless @logged
      @agent.get(url).save("#{destination}/#{name}.torrent")
    end
  end
  ##
  # Extract a list of results from your search
  class Search < TorrentSite::Search
    BASE_URL = 'https://yggtorrent.com'.freeze

    attr_accessor :url

    def initialize(search)
      # Order by seeds desc
      #@url = "#{BASE_URL}/engine/search?q=the+circle+2017"
      @query = search
      @url = "#{BASE_URL}/engine/search?q=#{URI.escape(search)}"
      @agent = Mechanize.new
      @agent.pluggable_parser['application/x-bittorrent'] = Mechanize::Download
      @logged = false
    end

    private

    def authenticate
      if $config['yggtorrent']
        Speaker.speak_up('Authenticating on yggtorrent.')
        login = @agent.get(BASE_URL + '/user/login')
        login_form = login.forms.first
        login_form.id = $config['yggtorrent']['username']
        login_form.pass = $config['yggtorrent']['password']
        @agent.submit login_form
        @logged = true
      else
        Speaker.speak_up('YggTorrent not configured, cannot authenticate')
      end
    end

    def page
      @page ||= @agent.get(@url)
    end

    def crawl_link(link)
      cols = link.xpath('.//td')
      links = cols[0].xpath('.//a')
      raw_size = cols[3].to_s
      size = raw_size.match(/[\d\.]+/).to_s.to_d
      s_unit = raw_size.gsub(/[\d\.]+ /,'').to_s
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
          'link' => links[1]['href'],
          'torrent_link' => links[2]['href'],
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
