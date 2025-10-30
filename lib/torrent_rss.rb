require_relative '../app/media_librarian/services/base_service'
require_relative '../app/media_librarian/services/tracker_login_service'

class TorrentRss

  def self.links(url, limit = NUMBER_OF_LINKS, tracker: nil)
    generate_links(url, limit, tracker: tracker)
  end

  private

  def self.crawl_link(link, url = '')
    desc = link.summary
    raw_size = desc.match(/Size: (\d+(\.\d+)? ?\w{2})/i)[1] rescue "0"
    size = raw_size.match(/[\d\.]+/).to_s.to_d
    s_unit = raw_size.match(/\w{2}/).to_s
    size = size_unit_convert(size, s_unit)
    download_source = link.image || link.url
    tlink = detect_link(download_source)
    download_link = tlink == 't' ? download_source : ''
    magnet_link = tlink == 'm' ? download_source : ''
    {
        :name => link.title.to_s.force_encoding('utf-8'),
        :size => size,
        :link => download_link.empty? ? magnet_link : download_link,
        :torrent_link => link.entry_id || link.url,
        :magnet_link => magnet_link,
        :seeders => (desc.match(/Seeders: (\d+)?/)[1] rescue 1),
        :leechers => (desc.match(/Leechers: (\d+)?/)[1] rescue 0),
        :id => link.title,
        :added => link.published,
        :tracker => url
    }
  end

  def self.detect_link(tlink)
    if tlink.match(/^magnet\:.*/)
      "m"
    else
      "t"
    end
  end

  def self.generate_links(url, limit = NUMBER_OF_LINKS, tracker: nil)
    links = []
    get_rows(url, tracker: tracker).each { |link| l = crawl_link(link, url); links << l unless l.nil? }
    links.first(limit)
  rescue Net::OpenTimeout, SocketError, Errno::EPIPE
    []
  rescue => e
    MediaLibrarian.app.speaker.tell_error(e, "TorrentRss.generate_links", 0)
    []
  end

  def self.get_rows(url, tracker: nil)
    agent = tracker_agent(tracker)
    (Feedjira.parse(agent.get(url).body)).entries || []
  rescue => e
    MediaLibrarian.app.speaker.tell_error(e, "TorrentRss.new('#{url}').get_rows")
  end

  def self.tracker_agent(tracker)
    metadata_path = tracker_metadata_path(tracker)
    return MediaLibrarian.app.mechanizer unless metadata_path && File.exist?(metadata_path)

    tracker_login_service.ensure_session(tracker)
  end

  def self.tracker_metadata_path(tracker)
    return if tracker.to_s.strip.empty?

    File.join(MediaLibrarian.app.tracker_dir, "#{tracker}.login.yml")
  end

  def self.tracker_login_service
    @tracker_login_service ||= MediaLibrarian::Services::TrackerLoginService
                                  .new(app: MediaLibrarian.app, speaker: MediaLibrarian.app.speaker)
  end

  def self.size_unit_convert(size, s_unit)
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

end