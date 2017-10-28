# media_librarian

What is it?
This program is made to answer my various needs for automation of the management of various media collections.

TODO:
* General
    * Refactor library.rb and add classes Movies, Music, TvSeries, Ebooks
    * Expire trakt authentication token and send email when needed
    * Function as a daemon launching any function possible with a scheduler
    
* Ebooks/Comics:
    * Read calibre library/metadata
    * Subscribe to series and/or authors, and search for new books/ebooks
    
* Music:
    * Subscribe to artists automatically and download and process new albums
    
* Torrent search:
    * Distinguish season pack and download if season episode not found and replace existing season with it
    * Track failed download in act upon failure
    
* Library:
    * Replace individual movies
    * Refactor function process_search_list to make it more generic, taking a standardized list as input to processing it to look on torrent trackers
    * Refactor function replace to make it more generic
    * Follow RSS feeds and download based on list input and filter