class TorrentRss

  def self.links(url, limit = NUMBER_OF_LINKS)
    generate_links(url, limit)
  end

  private

  def self.crawl_link(link, url = '')
    desc = link.summary
    raw_size = desc.match(/Size: (\d+(\.\d+)? ?\w{2})/i)[1] rescue "0"
    size = raw_size.match(/[\d\.]+/).to_s.to_d
    s_unit = raw_size.match(/\w{2}/).to_s
    size = size_unit_convert(size, s_unit)
    tlink = detect_link(link.image || link.url)
    {
        :name => link.title.to_s.force_encoding('utf-8'),
        :size => size,
        :link => link.entry_id || link.url,
        :torrent_link => tlink == 't' ? link.image || link.url : '',
        :magnet_link => tlink == 'm' ? link.image || link.url : '',
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

  def self.generate_links(url, limit = NUMBER_OF_LINKS)
    links = []
    get_rows(url).each { |link| l = crawl_link(link, url); links << l unless l.nil? }
    links.first(limit)
  rescue Net::OpenTimeout, SocketError, Errno::EPIPE
    []
  rescue => e
    MediaLibrarian.app.speaker.tell_error(e, "TorrentRss.generate_links", 0)
    []
  end

  def self.get_rows(url)
    (Feedjira.parse(MediaLibrarian.app.mechanizer.get(url).body)).entries || []
  rescue => e
    MediaLibrarian.app.speaker.tell_error(e, "TorrentRss.new('#{url}').get_rows")
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