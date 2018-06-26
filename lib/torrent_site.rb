require 'erb'
require 'open-uri'
require 'nokogiri'
require 'yaml'
require 'cgi'
require 'httparty'
module TorrentSite
  class Search
    NUMBER_OF_LINKS = 50
    attr_accessor :url

    def download(url, destination, name)
      authenticate! if PRIVATE_TRACKERS.map { |_, u| u }.include?(@base_url) && !$tracker_client_logged[@base_url]
      return '' if PRIVATE_TRACKERS.map { |_, u| u }.include?(@base_url) && !$tracker_client_logged[@base_url]
      path = "#{destination}/#{name}.torrent"
      url = @base_url + '/' + url if url.start_with?('/')
      $tracker_client[@base_url].download(url, path)
      path
    end

    def init
      $tracker_client[@base_url] = Cavy.new
      if PRIVATE_TRACKERS.map { |_, u| u }.include?(@base_url)
        $tracker_client_logged[@base_url] = false
        authenticate!
      end
    end

    def links(limit = NUMBER_OF_LINKS)
      generate_links(limit)
    end

    def post_init
      init if $tracker_client[@base_url].nil?
    end

    def size_unit_convert(size, s_unit)
      case s_unit
        when 'KB', 'KiB', 'kB'
          size *= 1024
        when 'MB', 'MiB'
          size *= 1024 * 1024
        when 'GB', 'GiB'
          size *= 1024 * 1024 * 1024
        when 'TB', 'TiB'
          size *= 1024 * 1024 * 1024 * 1024
      end
      size
    end

    private

    def authenticate!
      if $config[tracker]
        $speaker.speak_up("Authenticating on #{tracker}.", 0)
        begin
          auth
          $tracker_client_logged[@base_url] = true
        rescue => e
          $speaker.tell_error(e, "#{tracker}.authenticate!")
          $tracker_client_logged[@base_url] = false
        end
      else
        $speaker.speak_up("'#{tracker}' not configured, cannot authenticate")
      end
    end

    def generate_links(limit = NUMBER_OF_LINKS)
      links = []
      Utils.lock_block("torrentsite-#{@base_url}") {
        get_rows.each { |link| l = crawl_link(link); links << l unless l.nil? }
      }
      links.first(limit)
    rescue Net::OpenTimeout
      []
    rescue => e
      $speaker.tell_error(e, "TorrentSite[#{@base_url}].generate_links", 0)
      []
    end

    def get_rows
      authenticate! if PRIVATE_TRACKERS.map { |_, u| u }.include?(@base_url) && !$tracker_client_logged[@base_url]
      $speaker.speak_up "Fetching url '#{@url}'" if Env.debug?
      $tracker_client[@base_url].get_url(@url)
      $tracker_client[@base_url].all(@css_path)[0..50] || []
    end

    def tracker
      TORRENT_TRACKERS.key(@base_url) || @url
    end
  end
end