require 'erb'
require 'open-uri'
require 'nokogiri'
require 'yaml'
require 'cgi'
require 'httparty'
module TorrentSite
  class Download
    def self.download(url, destination, name)
      File.open("#{destination}/#{name}.torrent", 'ab+') do |line|
        line.puts self.request(url)
      end
    end

    def self.request(url)
      HTTParty.get(url).body
    rescue => e
      $speaker.tell_error(e, "Extratorrent::Download.request")
      nil
    end
  end
  ##
  # Extract a list of results from your search
  # ExtratorrentSearch::Search.new("Suits s05e16")
  class Search
    NUMBER_OF_LINKS = 50
    attr_accessor :url

    def links(limit = NUMBER_OF_LINKS)
      @links ||= generate_links(limit)
    end

    def results_found?
      @results_found ||= !get_rows.empty?
    rescue OpenURI::HTTPError
      @results_found = false
    end

    private

    def generate_links(limit = NUMBER_OF_LINKS)
      links = {'torrents' => [], 'query' => @query}
      return links unless results_found?
      link_nodes = get_rows
      links['total'] = link_nodes.length
      link_nodes.each { |link| links['torrents'] << crawl_link(link) }
      links['torrents'] = links['torrents'].first(limit)
      links
    end
  end
end