module Services
  class CustomListService
    def self.create(**options)
      new.create(**options)
    end

    def initialize(speaker: $speaker)
      @speaker = speaker
    end

    def create(name:, description:, origin: 'collection', criteria: {}, no_prompt: 0)
      speaker.speak_up("Fetching items from #{origin}...", 0)
      new_list = {
        'movies' => TraktAgent.list(origin, 'movies'),
        'shows' => TraktAgent.list(origin, 'shows')
      }
      dest_list = TraktAgent.list('lists').find { |l| l['name'] == name }
      to_delete = {}
      if dest_list
        speaker.speak_up("List #{name} exists", 0)
        to_delete = TraktAgent.parse_custom_list(TraktAgent.list(name))
      else
        speaker.speak_up("List #{name} doesn't exist, creating it...")
        TraktAgent.create_list(name, description)
      end
      speaker.speak_up("Ok, we have added #{(new_list['movies'].length + new_list['shows'].length)} items from #{origin}, let's chose what to include in the new list #{name}.", 0)
      ['movies', 'shows'].each do |type|
        process_type(new_list, type, criteria[type] || {}, to_delete, name, no_prompt)
      end
      speaker.speak_up("List #{name} is up to date!", 0)
    end

    private

    attr_reader :speaker

    def process_type(new_list, type, t_criteria, to_delete, name, no_prompt)
      if (t_criteria['noadd'] && t_criteria['noadd'].to_i > 0) || speaker.ask_if_needed("Do you want to add #{type} items? (y/n)", no_prompt, 'y') != 'y'
        new_list.delete(type)
        new_list[type] = to_delete[type] if t_criteria['add_only'].to_i > 0 && to_delete && to_delete[type]
        return
      end
      folder = speaker.ask_if_needed("What is the path of your folder where #{type} are stored? (in full)", t_criteria['folder'].nil? ? 0 : 1, t_criteria['folder'])
      ['released_before', 'released_after', 'days_older', 'days_newer', 'entirely_watched', 'partially_watched',
       'ended', 'not_ended', 'watched', 'canceled'].each do |cr|
        next unless speaker.ask_if_needed("Enter the value to keep only #{type} #{cr.gsub('_', ' ')}: (empty to not use this filter)", no_prompt, t_criteria[cr]).to_s != ''
        new_list[type] = TraktAgent.filter_trakt_list(new_list[type], type, cr, t_criteria['include'], t_criteria['add_only'], to_delete[type], t_criteria[cr], folder)
      end
      if t_criteria['review'] || speaker.ask_if_needed("Do you want to review #{type} individually? (y/n)", no_prompt, 'n') == 'y'
        review_list(new_list, type, t_criteria, folder, to_delete, no_prompt)
      end
      new_list[type].map! do |i|
        i[type[0...-1]]['seasons'] = i['seasons'].map { |s| s.select { |k, _| k != 'episodes' } } if i['seasons']
        i[type[0...-1]]
      end
      speaker.speak_up('Updating items in the list...', 0)
      TraktAgent.remove_from_list(to_delete[type], name, type) unless to_delete.nil? || to_delete.empty? || to_delete[type].nil? || to_delete[type].empty? || t_criteria['add_only'].to_i > 0
      TraktAgent.add_to_list(new_list[type], name, type)
    end

    def review_list(new_list, type, t_criteria, folder, to_delete, no_prompt)
      review_cr = t_criteria['review'] || {}
      speaker.speak_up('Preparing list of files to review...', 0)
      new_list[type].reverse_each do |item|
        title, _year = extract_title_and_year(item, type)
        folders = FileUtils.search_folder(folder, { 'regex' => StringUtils.title_match_string(title), 'maxdepth' => (type == 'shows' ? 1 : nil), 'includedir' => 1, 'return_first' => 1 })
        file = folders.first
        size = file ? FileUtils.get_disk_size(file[0]) : -1
        if size.to_d < 0 && (review_cr['remove_deleted'].to_i > 0 || speaker.ask_if_needed("No folder found for #{title}, do you want to delete the item from the list? (y/n)", no_prompt, 'n') == 'y')
          speaker.speak_up "No folder found for '#{title}', removing from list" if Env.debug?
          new_list[type].delete(item)
          next
        end
        unless keep_item?(new_list, type, item, t_criteria, to_delete, review_cr, title, size, no_prompt)
          next
        end
        next unless handle_seasons(type, item, review_cr, title, no_prompt)
        print '.'
      end
    end

    def extract_title_and_year(item, type)
      title = item[type[0...-1]]['title']
      year = item[type[0...-1]]['year']
      title = "#{title} (#{year})" if year.to_i > 0 && type == 'movies'
      [title, year]
    end

    def keep_item?(new_list, type, item, t_criteria, to_delete, review_cr, title, size, no_prompt)
      if (t_criteria['add_only'].to_i == 0 || !TraktAgent.search_list(type[0...-1], item, to_delete[type])) &&
         (t_criteria['include'].nil? || !t_criteria['include'].include?(title)) &&
         speaker.ask_if_needed("Do you want to add #{type} '#{title}' (disk size #{[(size.to_d / 1024 / 1024 / 1024).round(2), 0].max} GB) to the list (y/n)", review_cr['add_all'].to_i, 'y') != 'y'
        speaker.speak_up "Removing '#{title}' from list" if Env.debug?
        new_list[type].delete(item)
        return false
      end
      true
    end

    def handle_seasons(type, item, review_cr, title, no_prompt)
      return true unless type == 'shows'
      return true if review_cr['add_all'].to_i > 0 && review_cr['no_season'].to_i.zero?
      return true unless (review_cr['add_all'].to_i.zero? || review_cr['no_season'].to_i > 0) &&
                          ((review_cr['add_all'].to_i.zero? && review_cr['no_season'].to_i > 0) || speaker.ask_if_needed("Do you want to keep all seasons of #{title}? (y/n)", no_prompt, 'n') != 'y')
      choice = speaker.ask_if_needed("Which seasons do you want to keep? (separated by comma, like this: '1,2,3', empty for none", no_prompt, '').split(',')
      if choice.empty?
        item['seasons'] = nil
      else
        item['seasons'].select! { |s| choice.map! { |n| n.to_i }.include?(s['number']) }
      end
      true
    end
  end
end
