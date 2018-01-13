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

    def download(url, destination, name)
      authenticate! if PRIVATE_TRACKERS.map{|_, u| u}.include?(@base_url) && !$tracker_client_logged[@base_url]
      return if PRIVATE_TRACKERS.map{|_, u| u}.include?(@base_url) && !$tracker_client_logged[@base_url]
      path = "#{destination}/#{name}.torrent"
      $tracker_client[@base_url].get(url).save(path)
      path
    end

    def links(limit = NUMBER_OF_LINKS)
      generate_links(limit)
    end

    def results_found?
      @results_found ||= !get_rows.empty?
    rescue OpenURI::HTTPError
      @results_found = false
    end

    def post_init
      if $tracker_client[@base_url].nil?
        $tracker_client[@base_url] = Mechanize.new
        $tracker_client[@base_url].user_agent_alias = 'Mac Firefox'
        $tracker_client[@base_url].history.max_size = 0
        $tracker_client[@base_url].history_added = Proc.new {sleep 1}
        $tracker_client[@base_url].pluggable_parser['application/x-bittorrent'] = Mechanize::Download
        $tracker_client_logged[@base_url] = false if PRIVATE_TRACKERS.map{|_, u| u}.include?(@base_url) && !$tracker_client_logged[@base_url]
      end
    end

    def pre_auth
      authenticate! if PRIVATE_TRACKERS.map{|_, u| u}.include?(@base_url) && !$tracker_client_logged[@base_url]
    rescue => e
      $speaker.tell_error(e, "TorrentSite.pre_auth(#{@base_url})")
      $tracker_client_logged[@base_url] = false
    end

    private

    def tracker
      TORRENT_TRACKERS.key(@base_url) || @url
    end

    def page
      authenticate! if PRIVATE_TRACKERS.map{|_, u| u}.include?(@base_url) && !$tracker_client_logged[@base_url]
      $tracker_client[@base_url].get(@url)
    end

    def generate_links(limit = NUMBER_OF_LINKS)
      links = []
      return links unless results_found?
      get_rows.each { |link| l = crawl_link(link); links << l unless l.nil? }
      links.first(limit)
    rescue RARBG::APIError, Net::OpenTimeout
      []
    rescue => e
      $speaker.tell_error(e, "TorrentSite[#{@base_url}].generate_links")
      []
    end
  end
end