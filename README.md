# media_librarian

What is it?
This program is made to answer my various needs for automation of the management of various media collections.

TODO:
* General
    * Expire trakt authentication token and send email when needed
    * Function as a daemon launching any function possible with a scheduler
    * Load other templates from inside templates with keyword "load_template:"
    * Refactor environment flags to a single global variable "$env_flags = {}" and update simple_args_dispatch gem to read them without hardcoding every flag
    
* Ebooks/Comics:
    * Read calibre library/metadata
    * Subscribe to series and/or authors, and search for new books/ebooks
    
* Torrent search:
    * Distinguish season pack and download if season episode not found and replace existing season with it
    
* Library:
    * Replace individual movies
    * Refactor function process_search_list to make it more generic, taking a standardized list as input to processing it to look on torrent trackers