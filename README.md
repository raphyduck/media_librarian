# media_librarian

WARNING: Alpha stage. Expect things to break and sky to fall.

What is it?
This program is made to answer my various needs for automation in the management of various media collections.

TODO:
* General
    * Bypass cloudflare js check for tracker search (https://github.com/HatBashBR/HatCloud/blob/master/hatcloud.rb ? )
    * Parse YAML template file and alert in case of errors
    * Rename all command line funtion arguments to append suffix indicating type (like "no_prompt_int") to allow dynamic configuration. Arguments should be suffixed on the fly in args dispatch gem
    * Web UI/GUI with assisted configuration
    * Automatically check for new commits on master and auto-update (as a task)
    
* Ebooks/Comics:
    * Subscribe to series and/or authors, and search for new ebooks/comics
    
* Music:
    * Subscribe to artists automatically and download and process new albums
    
* Movies
    * List missing movies from movies set
    * Automatically watch future movies releases and add them to watchlist based on criteria (genres,?)

* Torrent search:
    
* TvSeries:
    * Download proper when they are published even if medium already seen
    
* Library:
    * Copy from imdb watchlist to trakt
    * Use alternative sources to identify series