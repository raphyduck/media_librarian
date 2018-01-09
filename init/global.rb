#String comparator
$str_closeness = FuzzyStringMatch::JaroWinkler.create(:pure)
#Set global variables
$tracker_client = {}
$tracker_client_logged = {}
#Some constants
CACHING_TTL = 14400
USER_INPUT_TIMEOUT = 600
NEW_LINE = "\n"
LINE_SEPARATOR = '---------------------------------------------------------'
RESOLUTIONS = %w(2160p 1080p 1080i 720p 720i hr 576p 480p 368p 360p)
SOURCES = %w(bluray remux dvdrip webdl web hdtv webrip bdscr dvdscr sdtv dsr tvrip preair ppvrip hdrip r5 workprint)
CODECS = %w(10bit h265 x265 h264 x264 xvid divx)
AUDIO = %w(truehd dts dtshd flac dd+5.1 ac3 dd5.1 aac2.0 aac mp3)
LANGUAGES = %w(multi vo eng french vfq vff vf german)
VALID_QUALITIES = RESOLUTIONS + SOURCES + CODECS + AUDIO + LANGUAGES
FILENAME_NAMING_TEMPLATE=%w(
    full_name
    destination_folder
    movies_name
    series_name
    episode_season
    episode_numbering
    episode_name
    quality
    proper
)
SEP_CHARS='[ \.\(\)\-]'
REGEX_QUALITIES=Regexp.new('(?=(' + SEP_CHARS + '(' + VALID_QUALITIES.join('|') + ')' + SEP_CHARS + '))')
SPACE_SUBSTITUTE='\. _'
BASIC_EP_MATCH='((([\. ]|^)[sS]|[' + SPACE_SUBSTITUTE + '\^\[])(\d{1,3})[exEX](\d{1,4})(\.(\d))?[\&-]?([exEX](\d{1,2})(\.(\d))?)?[\&-]?([exEX](\d{1,2})(\.(\d))?)?|([\. ]|^)[sS](\d{1,3}))'
REGEX_TV_EP_NB=/#{BASIC_EP_MATCH}([\. ]|$)|(^|\/|[#{SPACE_SUBSTITUTE}\[])(\d{3,4})[#{SPACE_SUBSTITUTE}\]]/
REGEX_BOOK_NB=Regexp.new('^(.*)[' + SPACE_SUBSTITUTE + '-]{1,2}((HS|T)(\d{1,4})?)[' + SPACE_SUBSTITUTE + '-]{1,3}(.*)', Regexp::IGNORECASE)
REGEX_BOOK_NB2=/^(.*)\(([^#]{5,}), (#(\d+))\)$/
VALID_VIDEO_EXT='(.*)\.(mkv|avi|mp4|mpg|m4v|mpg|divx)$'
PRIVATE_TRACKERS = {'yggtorrent' => 'https://yggtorrent.com',
                    'torrentleech' => 'https://www.torrentleech.org',
                    'wop' => 'https://worldofp2p.net'}
TORRENT_TRACKERS = PRIVATE_TRACKERS.merge({'rarbg' => 'https://rarbg.to',
                                           'thepiratebay' => 'https://thepiratebay.org'})
FOLDER_HIERARCHY = {
    'shows' => 3,
    'movies' => 0
}
VALID_VIDEO_MEDIA_TYPE=['movies', 'shows']
DEFAULT_MEDIA_DESTINATION = {
    'movies' => Dir.home + '/home/user/Movie/{{ movies_name }}/{{ movies_name|titleize|nospace }}.{{ quality|downcase|nospace }}.{{ proper|downcase }}',
    'shows' => Dir.home + '/home/user/TV_Shows/{{ series_name }}/Season {{ episode_season }}/{{ series_name|titleize|nospace }}.{{ episode_numbering|nospace }}.{{ episode_name|titleize|nospace }}.{{ quality|downcase|nospace }}.{{ proper|downcase }}'
}
IRRELEVANT_EXTENSIONS = ['srt', 'nfo', 'txt', 'url']
METADATA_SEARCH = {
    :type_enum => {
        :tv_show_get => 1,
        :movie_lookup => 2,
        :trakt => 3,
        :tv_episodes_search => 4,
        :tv_show_search => 5,
        :book_search => 6,
        :books_series_get => 7,
        :book_series_search => 8,
        :movie_get => 9
    }
}