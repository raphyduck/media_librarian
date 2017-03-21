require File.dirname(__FILE__) + '/torrent_site'
module Extratorrent
  class Download < TorrentSite::Download
  end
  ##
  # Extract a list of results from your search
  # ExtratorrentSearch::Search.new("Suits s05e16")
  class Search < TorrentSite::Search
    BASE_URL = 'https://extratorrent.cc'.freeze

    attr_accessor :url

    def initialize(search, cid = '')
      # Order by seeds desc
      #@url = "#{BASE_URL}/search/?search=#{ERB::Util.url_encode(search)}&srt=seeds&order=desc"
      @query = search
      @url = "#{BASE_URL}/rss.xml?type=search&search=#{search}&cid=#{cid}"
    end

    private

    def page
      @page ||= Nokogiri::XML(open(@url))
    end

    def crawl_link(link)
      {
          'name' => link.css('title')[0].text,
          'size' => link.css('size')[0].text,
          'link' => link.css('link')[0].text,
          'torrent_link' => link.css('enclosure').attr('url').value,
          'magnet_link' => link.css('magnetURI')[0].text,
          'seeders' => link.css('seeders')[0].text,
          'leechers' => link.css('leechers')[0].text,
          'id' => link.css('info_hash')[0].text,
          'added' => link.css('pubDate')[0].text,
      }
    end

    def get_rows
      page.xpath('//item')
    end
  end
end
