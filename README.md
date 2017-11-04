# media_librarian

What is it?
This program is made to answer my various needs for automation in the management of various media collections.

TODO:
* General
    * Expire trakt authentication token and send email when needed
    * Function as a daemon launching any function possible with a scheduler
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
    * Track failed download in act upon failure
    
* Library:
    * Add model for Movie, TvSeries and Show to combine sources from multiple inputs and allow caching
    * Use alternative sources to identify series
    * Merge MediaInfo.tv_series_search and MediaInfo.tv_show_search
    * Refactor function process_search_list to make it more generic, taking a standardized list as input to processing it to look on torrent trackers
    * Follow RSS feeds and download based on list input and filter