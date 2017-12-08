require File.dirname(__FILE__) + '/torrent_site'
module Yggtorrent
  ##
  # Extract a list of results from your search
  class Search < TorrentSite::Search

    attr_accessor :url

    def initialize(search, url = nil, cid = '')
      @base_url = 'https://yggtorrent.com'
      # Order by seeds desc
      @query = search
      @url = url || (search.to_s == '' ? "#{@base_url}/torrents/today?#{cid}" : "#{@base_url}/engine/search?#{cid}q=#{URI.escape(search)}")
      if $tracker_client[@base_url].nil?
        $tracker_client[@base_url] = Mechanize.new
        $tracker_client[@base_url].pluggable_parser['application/x-bittorrent'] = Mechanize::Download
        $tracker_client_logged[@base_url] = false
      end
    end

    private

    def authenticate!
      if $config['yggtorrent']
        $speaker.speak_up('Authenticating on yggtorrent.')
        login = $tracker_client[@base_url].get(@base_url + '/user/login')
        login_form = login.forms[1]
        login_form.id = $config['yggtorrent']['username']
        login_form.pass = $config['yggtorrent']['password']
        $tracker_client[@base_url].submit login_form
        $tracker_client_logged[@base_url] = true
      else
        $speaker.speak_up('YggTorrent not configured, cannot authenticate')
      end
    end

    def crawl_link(link)
      cols = link.xpath('.//td')
      links = cols[0].xpath('.//a')
      tlink = links[1]['href']
      tlink = links[2]['href'] if !tlink.match('download_torrent')
      raw_size = cols[3].to_s
      size = raw_size.match(/[\d\.]+/).to_s.to_d
      s_unit = raw_size.gsub(/<td>[\d\.]+/,'').gsub('</td>','').to_s.strip
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
          :link => links[0]['href'],
          :torrent_link => tlink,
          :magnet_link => '',
          :seeders => cols[4].text.to_i,
          :leechers => cols[5].text.to_i,
          :id => links[0].text.gsub(/\/torrent\/(\d+)\/.*/,'\1').to_s,
          :added => cols[2].text.gsub(/\n/,''),
          :tracker => tracker
      }
    end

    def get_rows
      rows = page.xpath('.//table/tbody/tr')[0..50]
      rows = page.xpath('.//table/tr')[0..50] || []  if rows.nil? || rows.empty?
      rows
    end
  end
end
