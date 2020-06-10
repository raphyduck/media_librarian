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
      return '' unless ensure_logged_in(@base_url)
      path = "#{destination}/#{name}.torrent"
      FileUtils.rm(path) if File.exist?(path)
      url = @base_url + '/' + url if url.start_with?('/')
      Utils.lock_block("torrentsite-#{@base_url}") do
        $tracker_client[@base_url].download(url, path)
      end
      path
    end

    def ensure_logged_in(vurl = nil)
      success = true
      Utils.lock_block("torrentsite-#{@base_url}") do
        if $config[tracker]
          begin
            if defined?(@logged_in_css) && @logged_in_css.to_s != '' && !($tracker_client[@base_url].all(:css, @logged_in_css) rescue []).empty?
              $speaker.speak_up "Already logged in, no need to authenticate again", 0 if Env.debug?
            elsif $tracker_client_last_login[@base_url].is_a?(Time) && $tracker_client_last_login[@base_url] >= Time.now - 24.hours
              $speaker.speak_up "Tried to log in less than 24h ago, skipping..." if Env.debug?
              success = false
            else
              $speaker.speak_up("Authenticating on #{tracker}.", 0) if Env.debug?
              $tracker_client_last_login[@base_url] = Time.now
              $tracker_client[@base_url].get_url(defined?(@login_url) && @login_url ? @login_url : @base_url)
              auth
            end
          rescue => e
            $speaker.tell_error(e, "#{tracker}.ensure_logged_in('#{vurl}')")
            success = false
          end
          $tracker_client[@base_url].get_url(vurl) if vurl && $tracker_client[@base_url].current_url != vurl
        else
          $speaker.speak_up("'#{tracker}' not configured, cannot authenticate")
          success = false
        end
      end
      $tracker_client[@base_url].reset! unless success
      success
    end

    def links(limit = NUMBER_OF_LINKS)
      generate_links(limit)
    end

    def post_init
      $tracker_client[@base_url] = Cavy.new if $tracker_client[@base_url].nil?
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
        get_rows.each { |link| l = crawl_link(link); links << l unless l.nil? }
      }
      links.first(limit)
    rescue Net::OpenTimeout, SocketError, Errno::EPIPE
      []
    rescue => e
      $speaker.tell_error(e, "TorrentSite[#{@base_url}].generate_links", 0)
      []
    end

    def get_rows
      gr = []
      $speaker.speak_up "Fetching url '#{@url}'" if Env.debug?
      $tracker_client[@base_url].get_url(@url)
      gr = $tracker_client[@base_url].all(@css_path, {wait: 30})[0..50] || [] rescue [] if !defined?(@force_login) || @force_login.to_i == 0 || ensure_logged_in(@url)
      $speaker.speak_up "Search '#{@url}' didn't return any results!" if gr.empty?
      gr
    end

    def tracker
      TORRENT_TRACKERS.select{|_,s| s.include?(@base_url)}.first[0] || @url
    end
  end
end