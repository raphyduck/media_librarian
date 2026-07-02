# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../app/music_search'

class MusicSearchSsrfTest < Minitest::Test
  def test_accepts_public_http_and_magnet_links
    assert MusicSearch.safe_download_link?('https://tracker.example.org/dl/1.torrent')
    assert MusicSearch.safe_download_link?('http://tracker.example.org/dl/1.torrent')
    assert MusicSearch.safe_download_link?('magnet:?xt=urn:btih:abcdef')
    assert MusicSearch.safe_download_link?('') # nothing is fetched for a blank link
  end

  def test_rejects_loopback_and_link_local_targets
    refute MusicSearch.safe_download_link?('http://127.0.0.1:8080/x')
    refute MusicSearch.safe_download_link?('http://localhost/x')
    refute MusicSearch.safe_download_link?('http://169.254.169.254/latest/meta-data/')
    refute MusicSearch.safe_download_link?('http://[::1]/x')
  end

  def test_rejects_non_http_schemes
    refute MusicSearch.safe_download_link?('file:///etc/passwd')
    refute MusicSearch.safe_download_link?('ftp://example.org/x')
    refute MusicSearch.safe_download_link?('gopher://example.org/x')
  end

  def test_allows_rfc1918_lan_hosts
    # Self-hosted / private trackers on the LAN must keep working.
    assert MusicSearch.safe_download_link?('http://192.168.1.10:9117/dl/1.torrent')
    assert MusicSearch.safe_download_link?('http://10.0.0.5/dl')
  end
end
