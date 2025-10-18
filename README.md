# media_librarian

WARNING: This is beta software. It might not work as intended.

What is it?
This program is made to answer my various needs for automation in the management of various media collections.

Requirements:
* Linux
* jackett: https://github.com/Jackett/Jackett
* flac
* lame
* mediainfo
* ffmpeg
* mkvmerge
* MakeMKV

TODO:
* General
    * Parse YAML template file and alert in case of errors
    * Rename all command line function arguments to append suffix indicating type (like "no_prompt_int") to allow dynamic configuration. Arguments should be suffixed on the fly in args dispatch gem
    * Web UI/GUI with assisted configuration
    * Automatically check for new commits on master and auto-update (as a task)
    * Install external requirements like chromium from inside the application
    * Restart daemon
    * Make it cross-platform
    * Trackers as templates
    
* Ebooks/Comics:
    
* Music:
    * Subscribe to artists automatically and download and process new albums
    
* Movies
    * Automatically watch future movies releases and add them to watchlist based on criteria (genres,?)

* Torrent search:
    
* TvSeries:
    
* Library:
    * Better management of languages
    * Automatic subtitling for videos. based on https://github.com/agermanidis/autosub (when technology will be good enough, or as a good AI project)
    * Use alternative sources to identify series
    * Do not count as duplicates if languages differ