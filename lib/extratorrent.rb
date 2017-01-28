require 'erb'
require 'open-uri'
require 'nokogiri'
require 'yaml'
require 'cgi'
require 'httparty'

module Extratorrent
  class Download
    def self.download(url, destination, name)
      File.open("#{destination}/#{name}.torrent", 'ab+') do |line|
        line.puts self.request(url)
      end
    end

    def self.request(url)
      HTTParty.get(url).body
    rescue => e
      Speaker.tell_error(e, "Extratorrent::Download.request")
      nil
    end
  end
  ##
  # Extract a list of results from your search
  # ExtratorrentSearch::Search.new("Suits s05e16")
  class Search
    NUMBER_OF_LINKS = 50
    BASE_URL = 'https://extratorrent.cc'.freeze

    attr_accessor :url

    def initialize(search, cid = '')
      # Order by seeds desc
      #@url = "#{BASE_URL}/search/?search=#{ERB::Util.url_encode(search)}&srt=seeds&order=desc"
      @query = search
      @url = "#{BASE_URL}/rss.xml?type=search&search=#{search}&cid=#{cid}"
    end

    def links(limit = NUMBER_OF_LINKS)
      @links ||= generate_links(limit)
    end

    def results_found?
      @results_found ||= !page.xpath('//item').empty?
    rescue OpenURI::HTTPError
      @results_found = false
    end

    private

    def page
      @page ||= Nokogiri::XML(open(@url))
    end

    def crawl_link(link)
      {
          'name' => link.css('title')[0].text,
          'size' => link.css('size')[0].text,
          'link' => link.css('enclosure').attr('url').value,
          'magnet_link' => link.css('magnetURI')[0].text,
          'seeders' => link.css('seeders')[0].text,
          'leechers' => link.css('leechers')[0].text,
          'id' => link.css('info_hash')[0].text,
          'added' => link.css('pubDate')[0].text,
      }
    end

    def generate_links(limit = NUMBER_OF_LINKS)
      links = {'torrents' => [], 'query' => @query}
      return links unless results_found?
      link_nodes = page.xpath('//item')
      links['total'] = link_nodes.length
      link_nodes.each { |link| links['torrents'] << crawl_link(link) }

      links['torrents'] = links['torrents'].first(limit)
      links
    end
  end
end
