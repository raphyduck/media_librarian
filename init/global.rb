#Set global variables
$tracker_client = {}
$tracker_client_logged = {}
#Some constants
NEW_LINE = "\n"
LINE_SEPARATOR = '---------------------------------------------------------'
RESOLUTIONS = %w(2160p 1080p 1080i 720p 720i hr 576p 480p 368p 360p)
SOURCES = %w(bluray remux dvdrip webdl web hdtv webrip bdscr dvdscr sdtv dsr tvrip preair ppvrip hdrip r5 workprint)
CODECS = %w(10bit h265 x265 h264 x264 xvid divx)
AUDIO = %w(truehd dts dtshd flac dd+5.1 ac3 dd5.1 aac mp3)
VALID_QUALITIES = RESOLUTIONS + SOURCES + CODECS + AUDIO + %w(multi)
FILENAME_NAMING_TEMPLATE=%w(
    movies_name
    series_name
    episode_season
    episode_numbering
    episode_name
    quality
    proper
)
REGEX_QUALITIES=Regexp.new('[ \.\(\)\-](' + VALID_QUALITIES.join('|') + ')')
VALID_VIDEO_EXT='.*\.(mkv|avi|mp4|mpg|m4v)$'
PRIVATE_TRACKERS = [{:name => 'yggtorrent', :url => 'https://yggtorrent.com'},
                    {:name => 'torrentleech', :url => 'https://www.torrentleech.org'},
                    {:name => 'wop', :url => 'https://worldofp2p.net'}]
TORRENT_TRACKERS = PRIVATE_TRACKERS + [{:name => 'rarbg', :url => 'https://rarbg.to'},
                                       {:name => 'thepiratebay', :url => 'https://thepiratebay.org'}]
FOLDER_HIERARCHY = {
    'shows' => 2,
    'movies' => 0
}
VALID_VIDEO_MEDIA_TYPE=['movies', 'shows']
DEFAULT_MEDIA_DESTINATION = {
    'movies' => Dir.home + '{{ destination_folder }}/Movies/{{ movies_name }}/{{ movies_name|titleize|nospace }}.{{ quality|downcase|nospace }}.{{ proper|downcase }}',
    'shows' => Dir.home + '{{ destination_folder }}/TV_Shows/{{ series_name }}/Season {{ episode_season }}/{{ series_name|titleize|nospace }}.{{ episode_numbering|nospace }}.{{ episode_name|titleize|nospace }}.{{ quality|downcase|nospace }}.{{ proper|downcase }}'
}