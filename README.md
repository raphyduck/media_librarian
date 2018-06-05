# media_librarian

WARNING: Alpha stage. Expect things to break and sky to fall.

What is it?
This program is made to answer my various needs for automation in the management of various media collections.

Requirements:
* phantomjs

TODO:
* General
    * Reload and restart daemon
    * Parse YAML template file and alert in case of errors
    * Rename all command line funtion arguments to append suffix indicating type (like "no_prompt_int") to allow dynamic configuration. Arguments should be suffixed on the fly in args dispatch gem
    * Web UI/GUI with assisted configuration
    * Automatically check for new commits on master and auto-update (as a task)
    * Install external requirements like phantomjs from in-app
    
* Ebooks/Comics:
    
* Music:
    * Subscribe to artists automatically and download and process new albums
    
* Movies
    * List missing movies from movies set
    * Automatically watch future movies releases and add them to watchlist based on criteria (genres,?)

* Torrent search:
    * Allow replacing existing files by better quality if existing quality is less than target
    
* TvSeries:
    
* Library:
    * Use alternative sources to identify series