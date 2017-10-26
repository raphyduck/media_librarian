require 'erb'
require 'open-uri'
require 'nokogiri'
require 'yaml'
require 'cgi'
require 'httparty'
module TorrentSite
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

    def download(url, destination, name)
      authenticate! unless $tracker_client_logged[@base_url]
      return unless $tracker_client_logged[@base_url]
      $tracker_client[@base_url].get(url).save("#{destination}/#{name}.torrent")
    end

    private

    def page
      authenticate! if PRIVATE_TRACKERS.map{|x| x[:url]}.include?(@base_url) && !$tracker_client_logged[@base_url]
      @page ||= $tracker_client[@base_url].get(@url)
    end

    def generate_links(limit = NUMBER_OF_LINKS)
      links = {'torrents' => [], 'query' => @query}
      return links unless results_found?
      link_nodes = get_rows
      links['total'] = link_nodes.length
      link_nodes.each { |link| l = crawl_link(link); links['torrents'] << l unless l.nil? }
      links['torrents'] = links['torrents'].first(limit)
      links
    end
  end
end