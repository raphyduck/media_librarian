require File.dirname(__FILE__) + '/torrent_site'
module Tpb
  class Download < TorrentSite::Download
  end
  ##
  # Extract a list of results from your search
  # ExtratorrentSearch::Search.new("Suits s05e16")
  class Search < TorrentSite::Search
    BASE_URL = 'https://thepiratebay.se'.freeze

    attr_accessor :url

    def initialize(search, cid = '')
      # Order by seeds desc
      #@url = "#{BASE_URL}/search/?search=#{ERB::Util.url_encode(search)}&srt=seeds&order=desc"
      @query = search
      @url = "#{BASE_URL}/search/#{URI.escape(search)}/0/7/#{cid}"
    end

    private

    def page
      @page ||= Nokogiri::HTML(open(@url))
    end

    def crawl_link(link)
      cols = link.xpath('.//td')
      links = cols[1].xpath('.//a')
      meta_col = cols[1].xpath('.//font').text.gsub("\u00a0", ' ')
      _, created_at, raw_size, _ = %r{Uploaded (.*), Size (.*), ULed by (.*)}.match(meta_col).to_a
      size = raw_size.match(/[\d\.]+/).to_s.to_d
      s_unit = raw_size.gsub(/[\d\.]+ /,'').to_s
      case s_unit
        when 'MiB'
          size *= 1024 * 1024
        when 'GiB'
          size *= 1024 * 1024 * 1024
        when 'TiB'
          size *= 1024 * 1024 * 1024 * 1024
      end
      {
          'name' => links[0].text,
          'size' => size,
          'link' => BASE_URL + links[0]['href'],
          'magnet_link' => links[1]['href'],
          'seeders' => cols[2].text.to_i,
          'leechers' => cols[3].text.to_i,
          'id' => links[0]['href'].gsub(/\/torrent\/(\d+)\/.*/,'\1').to_i,
          'added' => created_at,
      }
    end

    def get_rows
      page.xpath('.//table/tr')[1..31] || []
    end
  end
end
