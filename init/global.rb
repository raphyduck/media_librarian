require_relative '../boot/librarian'
require_relative 'languages_translation'

app = MediaLibrarian::Boot.application
app.str_closeness
app.tracker_client
app.tracker_client_last_login

CACHING_TTL = 108_000
USER_INPUT_TIMEOUT = 600
NEW_LINE = "\n"
NUMBER_OF_LINKS = 100
LINE_SEPARATOR = '---------------------------------------------------------'
SPACER = '   '
RESOLUTIONS = %w[2160p 2160i 1080p 1080i 720p 720i 576p 576i 480p 480i 368p 360p 360i 240p 240i]
DIMENSIONS = %w[3d]
SOURCES = %w[bluray blu-ray bdrip brrip remux dvdrip webdl web-dl web hdtv webrip bdscr dvdscr sdtv dsr tvrip preair ppvrip hdrip r5 workprint]
CODECS = %w[10bits 10bit hevc h265 x265 avc h264 x264 xvid divx vc1 wmv mpeg2]
AUDIO = ['truehd', 'dts', 'dtshd', 'flac', 'dd+5.1', 'dd+5 1', 'ac3', 'ddp5.1', 'dd5.1', 'aac2.0', 'aac', 'mp3']
TONES = ['hdr', 'sdr']
CUT = ['director.s.cut', 'directors.cut', 'uncut', 'unrated', 'extended']
preferred_languages = app.config['preferred_languages']
LANGUAGES = ['multi', 'vo', 'vof', 'vostfr'] + Languages.sort_languages(preferred_languages)
EXTRA_TAGS = ['nodup']
Q_SORT = ['RESOLUTIONS', 'SOURCES', 'LANGUAGES', 'CODECS', 'AUDIO', 'TONES', 'CUT']
VALID_QUALITIES = DIMENSIONS + RESOLUTIONS + SOURCES + CODECS + AUDIO + LANGUAGES + TONES + CUT + EXTRA_TAGS
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
    part
)
VALID_CONVERSION_INPUTS = {
    :video => ['iso', 'ts', 'm2ts']
}
VALID_CONVERSION_OUTPUT = {
    :video => ['mkv']
}
VALID_MEDIA_TYPES = {
    :video => ['movies', 'shows']
}
EXTENSIONS_TYPE= {
    :video => %w(mkv avi mp4 mpg m4v mpg divx iso ts m2ts)
}
VALID_VIDEO_EXT="(.*)\\.(#{EXTENSIONS_TYPE[:video].join('|')})$"
SEP_CHARS='[\/ \.\(\)\-]'
REGEX_QUALITIES=Regexp.new('(?=(' + SEP_CHARS + '(' + VALID_QUALITIES.join('|') + ')' + SEP_CHARS + '))')
SPACE_SUBSTITUTE='\. _\-'
BASIC_EP_MATCH='((([' + SPACE_SUBSTITUTE + ']|^)[sS]|[' + SPACE_SUBSTITUTE + '\^\[])(\d{1,3})[exEX](\d{1,4})([' + SPACE_SUBSTITUTE + '](part|cd|disc|pt)(\d))?([\&\-exEX]{1,2}(\d{1,2})([' + SPACE_SUBSTITUTE + '](part|cd|disc|pt)(\d))?)?([\&\-exEX]{1,2}(\d{1,2})([' + SPACE_SUBSTITUTE + '](part|cd|disc|pt)(\d))?)?|([\. \-]|^)[sS](\d{1,3}))'
REGEX_TV_EP_NB=/#{BASIC_EP_MATCH}([#{SPACE_SUBSTITUTE}]|$)|(^|\/|[#{SPACE_SUBSTITUTE}\[])(\d{3,4})[#{SPACE_SUBSTITUTE}\]-]#{VALID_VIDEO_EXT}/
FOLDER_HIERARCHY = {
    'shows' => 3,
    'movies' => 0
}
DEFAULT_MEDIA_DESTINATION = {
    'movies' => Dir.home + '/Movie/{{ movies_name }}/{{ movies_name|titleize|nospace }}.{{ quality|downcase|nospace }}.{{ proper|downcase }}.{{ part|downcase }}',
    'shows' => Dir.home + '/TV_Shows/{{ series_name }}/Season {{ episode_season }}/{{ series_name|titleize|nospace }}.{{ episode_numbering|nospace }}.{{ episode_name|titleize|nospace }}.{{ quality|downcase|nospace }}.{{ proper|downcase }}'
}
DEFAULT_FILTER_PROCESSFOLDER = {
    'movies' => {
        'exclude_path' => ['Plex Versions']
    },
    'shows' => {
        'exclude_path' => ['Plex Versions']
    }
}
IRRELEVANT_EXTENSIONS = ['srt', 'nfo', 'txt', 'url']
METADATA_SEARCH = {
    :type_enum => {
        :tv_show_get => 1,
        :movie_lookup => 2,
        :trakt => 3,
        :tv_episodes_search => 4,
        :tv_show_search => 5,
        :movie_get => 6,
        :movie_set_get => 7
    }
}
