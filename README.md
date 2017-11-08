# media_librarian

What is it?
This program is made to answer my various needs for automation in the management of various media collections.

TODO:
* General
    * Expire trakt authentication token and send email when needed
    * Save state on shutdown (including torrents to download) and resume on start up
    * Refactor email notification - add an email sending task that would flush out all pending logs
    * Properly trap temination signal and flushes all pending operations before quitting
    * Bypass cloudflare js check for tracker search (https://github.com/HatBashBR/HatCloud/blob/master/hatcloud.rb ? )
    * Rename all command line funtion arguments to append suffix indicating type (like "no_prompt_int") to allow dynamic configuration. Arguments should be suffixed on the fly in args dispatch gem
    * Web UI/GUI with assisted configuration
    
* Ebooks/Comics:
    * Read calibre library/metadata
    * Subscribe to series and/or authors, and search for new ebooks/comics
    
* Music:
    * Subscribe to artists automatically and download and process new albums
    
* Movies
    * Automatically watch future movies releases and add them to watchlist based on criteria (genres,?)

* Torrent search:
    * Distinguish season pack and download if season episode not found and replace existing season with it
    
* Library:
    * Follow RSS feeds and download based on list input and filter
    * Use alternative sources to identify series