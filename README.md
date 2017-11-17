# media_librarian

What is it?
This program is made to answer my various needs for automation in the management of various media collections.

TODO:
* General
    * Expire trakt authentication token and send email when needed
    * Bypass cloudflare js check for tracker search (https://github.com/HatBashBR/HatCloud/blob/master/hatcloud.rb ? )
    * Expire @cache in media_info
    * Parse YAML template file and alert in case of errors
    * Speed up app, remove unnecessary dependency, avoid loading dependencies if just sending command to daemon (http://greyblake.com/blog/2012/09/02/ruby-perfomance-tricks/, https://github.com/byroot/bootscale/blob/master/README.md)
    * Rename all command line funtion arguments to append suffix indicating type (like "no_prompt_int") to allow dynamic configuration. Arguments should be suffixed on the fly in args dispatch gem
    * Web UI/GUI with assisted configuration
    * Automatically check for new commits on master and auto-update (as a task)
    
* Ebooks/Comics:
    * Read calibre library/metadata
    * Subscribe to series and/or authors, and search for new ebooks/comics
    
* Music:
    * Subscribe to artists automatically and download and process new albums
    
* Movies
    * List missing movies from movies set
    * Automatically watch future movies releases and add them to watchlist based on criteria (genres,?)

* Torrent search:
    * Distinguish season pack and download if season episode not found and replace existing season with it
    
* Library:
    * Use alternative sources to identify series