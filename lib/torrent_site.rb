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
      post_init
      return '' if PRIVATE_TRACKERS.map {|_, u| u}.include?(@base_url) && !$tracker_client_logged[@base_url]
      path = "#{destination}/#{name}.torrent"
      FileUtils.rm(path) if File.exist?(path)
      url = @base_url + '/' + url if url.start_with?('/')
      Utils.lock_block("torrentsite-#{@base_url}") do
        $tracker_client[@base_url].download(url, path)
      end
      path
    end

    def links(limit = NUMBER_OF_LINKS)
      generate_links(limit)
    end

    def post_init(quit_only = 0)
      return if quit_only.to_i > 0
      Utils.lock_block("torrentsite-#{@base_url}") do
        if $tracker_client[@base_url].nil?
          $tracker_client[@base_url] = Cavy.new
          $tracker_client_logged[@base_url] = false if PRIVATE_TRACKERS.map {|_, u| u}.include?(@base_url)
        end
        if PRIVATE_TRACKERS.map {|_, u| u}.include?(@base_url) && !$tracker_client_logged[@base_url]
          if $config[tracker]
            $speaker.speak_up("Authenticating on #{tracker}.", 0)
            begin
              auth
              $tracker_client_logged[@base_url] = true
            rescue => e
              $speaker.tell_error(e, "#{tracker}.post_init!")
            end
          else
            $speaker.speak_up("'#{tracker}' not configured, cannot authenticate")
          end
        end
      end
    end

    def quit
      Utils.lock_block("torrentsite-#{@base_url}") do
        $speaker.speak_up("Quitting tracker parser for '#{@base_url}'", 0) if Env.debug?
        unless $tracker_client[@base_url].nil?
          $tracker_client[@base_url].quit
          $tracker_client[@base_url] = nil
        end
      end
    end

    def size_unit_convert(size, s_unit)
      case s_unit
      when 'KB', 'KiB', 'kB', 'Ko', 'KO'
        size *= 1024
      when 'MB', 'MiB', 'Mo', 'MO'
        size *= 1024 * 1024
      when 'GB', 'GiB', 'Go', 'GO'
        size *= 1024 * 1024 * 1024
      when 'TB', 'TiB', 'To', 'TO'
        size *= 1024 * 1024 * 1024 * 1024
      end
      size
    end

    private

    def generate_links(limit = NUMBER_OF_LINKS)
      links = []
      Utils.lock_block("torrentsite-#{@base_url}") {
        get_rows.each {|link| l = crawl_link(link); links << l unless l.nil?}
      }
      links.first(limit)
    rescue Net::OpenTimeout, Faraday::ConnectionFailed, SocketError
      []
    rescue => e
      $speaker.tell_error(e, "TorrentSite[#{@base_url}].generate_links", 0)
      []
    end

    def get_rows
      post_init
      $speaker.speak_up "Fetching url '#{@url}'" if Env.debug?
      $tracker_client[@base_url].get_url(@url)
      $tracker_client[@base_url].all(@css_path, {wait: 30})[0..50] || []
    end

    def tracker
      TORRENT_TRACKERS.key(@base_url) || @url
    end
  end
end