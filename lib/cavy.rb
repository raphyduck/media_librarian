class Cavy
  def initialize(opts = {})
    @capybara = Capybara::Session.new(:poltergeist)
    @mechanize = Mechanize.new
    @mechanize.user_agent_alias = opts['user_agent'] || 'Mac Firefox'
    @mechanize.history.max_size = opts['max_history_size'] || 0
    @mechanize.history_added = Proc.new { sleep 1 }
    @mechanize.pluggable_parser['application/x-bittorrent'] = Mechanize::Download
    @capybara.driver.headers = { 'User-Agent' => @mechanize.user_agent }
  end

  def download(url, destination)
    tries ||= 3
    sync_cookies
    @mechanize.get(url).save(destination)
  rescue => e
    if (tries -= 1) >= 0
      visit(url)
      retry
    else
      raise e
    end
  end

  def get_url(url)
    tries ||= 3
    visit(url)
    true
  rescue => e
    if (tries -= 1) >= 0
      retry
    else
      $speaker.tell_error(e, "Cavy.get_url('#{url}')")
      false
    end
  end

  def method_missing(name, *args)
    if @capybara.respond_to?(name)
      @capybara.method(name).call(*args)
    elsif @mechanize.respond_to?(name)
      @mechanize.method(name).call(*args)
    else
      raise 'Invalid method'
    end
  end

  private

  def get_cookies
    @capybara.driver.browser.cookies.map { |_, v| (Cache.object_pack(v, 1) || {})['attributes'] }
  end

  def sync_cookies
    @mechanize.cookie_jar.clear!
    get_cookies.each do |c|
      @mechanize.cookie_jar << Mechanize::Cookie.new(
          :domain => c['domain'],
          :name => c['name'],
          :value => c['value'],
          :path => c['path'],
          :expires => c['expires']
      )
    end
  end

  def visit(url)
    @capybara.visit url
    sleep 3 #FIXME: find cleverer way to wait for page being loaded
  end

end