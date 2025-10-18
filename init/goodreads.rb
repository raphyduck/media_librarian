app = MediaLibrarian.app
goodreads = app.config['goodreads']

if goodreads && goodreads['api_key'] && goodreads['api_secret']
  app.goodreads = Goodreads::Client.new(api_key: goodreads['api_key'], api_secret: goodreads['api_secret'])
end