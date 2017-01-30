class TraktList
  def self.access_token(vals)
    {"access_token" => vals[1],
     "token_type" => "bearer",
     "expires_in" => (Time.parse(vals[4])-Time.now).to_i,
     "refresh_token" => vals[2],
     "scope" => "public"}
  end

  def self.add_to_list(items, list_type, list_name = '', type = 'movies')
    authenticate!
    items = [items] unless items.is_a?(Array)
    items.map! { |i| i.merge({'collected_at' => TIme.now}) } if list_type == 'collection'
    $trakt.sync.add_or_remove_item('add', list_type, type, items, list_name)
  end

  def self.create_list(name, description, privacy = 'private', display_numbers = false, allow_comments = true)
    $trakt.list.create_list({
                                'name' => name,
                                'description' => description,
                                'privacy' => privacy,
                                'display_numbers' => display_numbers,
                                'allow_comments' => allow_comments
                            })
  end

  def self.authenticate!
    raise 'No trakt account configured' unless $trakt
    token_rows = $db.get_rows('trakt_auth', "account = '#{$trakt_account}'")
    token_row = token_rows.first
    if token_row.nil? || Time.parse(token_row[4]) < Time.now
      token = $trakt.access_token
      $db.insert_row('trakt_auth', [$trakt_account, token['access_token'], token['refresh_token'], Time.now, Time.now + token['expires_in'].to_i.seconds]) if token
    else
      token = self.access_token(token_row)
    end
    $trakt.token = token
  end

  def self.list(name = 'watchlist', type = 'movies')
    authenticate!
    case name
      when 'watchlist'
        $trakt.list.watchlist(type)
      when 'collection'
        $trakt.list.collection(type)
      when 'lists'
        $trakt.list.get_user_lists
      else
        $trakt.list.list(name)
    end
  rescue => e
    Speaker.tell_error(e, "TraktList.list")
    []
  end

  def self.remove_from_list(items, list = 'watchlist', type = 'movies')
    authenticate!
    items = [items] unless items.is_a?(Array)
    if list == 'watchlist'
      $trakt.sync.mark_watched(items.map { |i| i.merge({'watched_at' => Time.now}) }, type)
    else
      $trakt.sync.add_or_remove_item('remove', list, type, items, list)
    end
  end
end