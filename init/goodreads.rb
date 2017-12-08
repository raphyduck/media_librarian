if $config['goodreads'] && $config['goodreads']['api_key'] && $config['goodreads']['api_secret']
  $goodreads = Goodreads::Client.new(api_key: $config['goodreads']['api_key'], api_secret: $config['goodreads']['api_secret'])
end