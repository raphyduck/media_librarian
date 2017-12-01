require File.dirname(__FILE__) + '/torrent_site'
module Tpb
  ##
  # Extract a list of results from your search
  # ExtratorrentSearch::Search.new("Suits s05e16")
  class Search < TorrentSite::Search

    attr_accessor :url

    def initialize(search, cid = '')
      @base_url = 'https://thepiratebay.org'
      @query = search
      @url = "#{@base_url}/search/#{URI.escape(search)}/0/7/#{cid}"
      $tracker_client[@base_url] = Mechanize.new if $tracker_client[@base_url].nil?
    end

    def download(url, destination, name)
      $speaker.speak_up('ThePirateBay do not provide torrent link')
      ''
    end

    private

    def crawl_link(link)
      cols = link.xpath('.//td')
      links = cols[1].xpath('.//a')
      meta_col = cols[1].xpath('.//font').text.gsub("\u00a0", ' ')
      _, created_at, raw_size, _ = %r{Uploaded (.*), Size (.*), ULed by (.*)}.match(meta_col).to_a
      size = raw_size.match(/[\d\.]+/).to_s.to_d
      s_unit = raw_size.gsub(/[\d\.]+ /,'').to_s.strip
      case s_unit
        when 'MiB'
          size *= 1024 * 1024
        when 'GiB'
          size *= 1024 * 1024 * 1024
        when 'TiB'
          size *= 1024 * 1024 * 1024 * 1024
      end
      {
          :name => links[0].text.to_s.force_encoding('utf-8'),
          :size => size,
          :link => @base_url + links[0]['href'],
          :magnet_link => links[1]['href'],
          :seeders => cols[2].text.to_i,
          :leechers => cols[3].text.to_i,
          :id => links[0]['href'].gsub(/\/torrent\/(\d+)\/.*/,'\1').to_i,
          :added => created_at,
          :tracker => tracker
      }
    end

    def get_rows
      page.xpath('.//table/tr')[0..50] || []
    end
  end
end
