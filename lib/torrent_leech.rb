require File.dirname(__FILE__) + '/torrent_site'
module TorrentLeech
  ##
  # Extract a list of results from your search
  class Search < TorrentSite::Search

    attr_accessor :url

    def initialize(search, url = nil, cid = '')
      @base_url = 'https://www.torrentleech.org'
      # Order by seeds desc
      @query = search
      @url = url || "#{@base_url}/torrents/browse/index/query/#{URI.escape(search.gsub(/\ \ +/,' '))}/newfilter/2/#{'facets/category%253A' + cid.to_s if cid.to_s != ''}#{'/orderby/seeders/order/desc' if search.to_s != ''}" #/torrents/browse/index/query/batman/newfilter/2orderby/seeders/order/desc
      if $tracker_client[@base_url].nil?
        $tracker_client[@base_url] = Mechanize.new
        $tracker_client[@base_url].pluggable_parser['application/x-bittorrent'] = Mechanize::Download
        $tracker_client_logged[@base_url] = false
      end
    end

    private

    def authenticate!
      if $config['torrentleech']
        $speaker.speak_up('Authenticating on TorrentLeech.')
        login = $tracker_client[@base_url].get(@base_url + '/')
        login_form = login.form('form')
        login_form.username = $config['torrentleech']['username']
        login_form.password = $config['torrentleech']['password']
        $tracker_client[@base_url].submit login_form
        $tracker_client_logged[@base_url] = true
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
      s_unit = raw_size.gsub(/<td [\w=\"]*>[\d\.]+/, '').gsub('</td>', '').to_s.strip
      case s_unit
        when 'MB'
          size *= 1024 * 1024
        when 'GB'
          size *= 1024 * 1024 * 1024
        when 'TB'
          size *= 1024 * 1024 * 1024 * 1024
      end
      {
          :name => links[0].text.to_s.force_encoding('utf-8'),
          :size => size,
          :link => @base_url + '/' + links[0]['href'],
          :torrent_link => tlink,
          :magnet_link => '',
          :seeders => cols[6].text.to_i,
          :leechers => cols[7].text.to_i,
          :id => link.attr('id'),
          :added => cols[1].css('span[class="addedInLine"]').text.to_s.match(/(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})/).to_s,
          :tracker => tracker
      }
    end

    def get_rows
      page.xpath('//table[@id="torrenttable"]/tbody/tr')[0..50] || []
    end
  end
end
