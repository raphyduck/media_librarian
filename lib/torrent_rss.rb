class TorrentRss < TorrentSite::Search
  attr_accessor :url

  def initialize(url)
    @url = url
    @base_url = url
    if $tracker_client[url].nil?
      $tracker_client[url] = Mechanize.new
      $tracker_client[url].pluggable_parser['application/x-bittorrent'] = Mechanize::Download
    end
  end

  private

  def crawl_link(link)
    desc = link.description
    raw_size = desc.match(/Size: (\d+(\.\d+)? \w{2})/i)[1] rescue "0"
    size = raw_size.match(/[\d\.]+/).to_s.to_d
    s_unit = raw_size.match(/\w{2}/).to_s
    case s_unit
      when 'MB'
        size *= 1024 * 1024
      when 'GB'
        size *= 1024 * 1024 * 1024
      when 'TB'
        size *= 1024 * 1024 * 1024 * 1024
    end
    {
        :name => link.title.to_s.force_encoding('utf-8'),
        :size => size,
        :link => link.guid,
        :torrent_link => link.link,
        :magnet_link => '',
        :seeders => (desc.match(/Seeders: (\d+)?/)[1] rescue 1),
        :leechers => (desc.match(/Leechers: (\d+)?/)[1] rescue 0),
        :id => link.title,
        :added => link.pubDate,
        :tracker => tracker
    }
  end

  def get_rows
    (SimpleRSS.parse open(url)).items || []
  end


end