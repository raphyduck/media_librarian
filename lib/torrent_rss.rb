require File.dirname(__FILE__) + '/torrent_site'
class TorrentRss < TorrentSite::Search
  attr_accessor :url

  def initialize(url, quit_only = 0)
    @url = url
    @base_url = url
    post_init(quit_only)
  end

  private

  def crawl_link(link)
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
        :tracker => tracker
    }
  end

  def detect_link(tlink)
    if tlink.match(/^magnet\:.*/)
      "m"
    else
      "t"
    end
  end

  def get_rows
    xml = HTTParty.get(url).body
    (Feedjira.parse(xml)).entries || []
  end


end