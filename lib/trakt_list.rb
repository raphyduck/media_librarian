class TraktList
  def self.access_token(vals)
    {"access_token"=>vals[1],
     "token_type"=>"bearer",
     "expires_in"=>(Time.parse(vals[4])-Time.now).to_i,
     "refresh_token"=>vals[2],
     "scope"=>"public"}
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
    if name == 'watchlist'
      $trakt.list.watchlist(type)
    else
      $trakt.list.list(name)
    end
  end

  def self.remove_from_list(items, list = 'watchlist', type = 'movies')
    authenticate!
    if list == 'watchlist'
      $trakt.sync.mark_watched(items, type)
    end
  end
end