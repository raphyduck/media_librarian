require File.dirname(__FILE__) + '/torrent_site'
module TorrentLeech
  ##
  # Extract a list of results from your search
  class Search < TorrentSite::Search

    attr_accessor :url

    def initialize(search, url = nil)
      @base_url = 'https://www.torrentleech.org'
      # Order by seeds desc
      @query = search
      @url = url || "#{@base_url}/torrents/browse/index/query/#{URI.escape(search)}/newfilter/2/orderby/seeders/order/desc" #/torrents/browse/index/query/batman/newfilter/2orderby/seeders/order/desc
      if @client.nil?
        @client = Mechanize.new
        @client.pluggable_parser['application/x-bittorrent'] = Mechanize::Download
        @client_logged = false
      end
    end

    private

    def authenticate!
      if $config['torrentleech']
        $speaker.speak_up('Authenticating on TorrentLeech.')
        login = @client.get(@base_url + '/')
        login_form = login.form('form')
        login_form.username = $config['torrentleech']['username']
        login_form.password = $config['torrentleech']['password']
        @client.submit login_form
        @client_logged = true
      else
        $speaker.speak_up('TorrentLeech not configured, cannot authenticate')
      end
    end

    def crawl_link(link)
      cols = link.xpath('.//td')
      links = cols[1].xpath('.//a')
      tlink = cols[2].xpath('.//a')[0]['href']
      raw_size = cols[4].to_s
      size = raw_size.match(/[\d\.]+/).to_s.to_d
      s_unit = raw_size.gsub(/<td [\w=\"]*>[\d\.]+/, '').gsub('</td>', '').to_s
      puts cols[1].css('span[class="addedInLine"]').text.to_s
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
          'torrent_link' => tlink,
          'magnet_link' => '',
          'seeders' => cols[6].text.to_i,
          'leechers' => cols[7].text.to_i,
          'id' => link.attr('id'),
          'added' => cols[1].css('span[class="addedInLine"]').text.to_s.match(/(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})/).to_s,
      }
    end

    def get_rows
      page.xpath('//table[@id="torrenttable"]/tbody/tr')[0..50] || []
    end
  end
end
