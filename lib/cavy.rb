class Cavy
  def initialize(opts = {})
    init_capybara
    @mechanize.user_agent_alias = opts['user_agent'] || "Linux Firefox"
    @mechanize.history.max_size = opts['max_history_size'] || 0
    @mechanize.history_added = Proc.new {sleep 1}
    @mechanize.pluggable_parser['application/x-bittorrent'] = Mechanize::Download
  end

  def init_capybara
    @capybara = Capybara::Session.new(:selenium_chrome_headless)
    @capybara.current_window.resize_to(1900, 1000)
    @mechanize = Mechanize.new
    #TODO: Same user agent for capybara and mechanize. How to get capybara user agent?
  end

  def download(url, destination)
    tries ||= 3
    sync_cookies
    @mechanize.get(url).save(destination)
  rescue => e
    if (tries -= 1) >= 0
      @capybara.visit url
      retry
    else
      raise e
    end
  end

  def get_url(url)
    tries ||= 3
    @capybara.visit url
    true
  rescue => e
    if (tries -= 1) >= 0
      retry
    else
      $speaker.tell_error(e, Utils.arguments_dump(binding))
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

  def sync_cookies
    @mechanize.cookie_jar.clear!
    @capybara.driver.browser.manage.all_cookies.each do |c|
      c[:expires] = DateTime.now + 1.year
      @mechanize.cookie_jar << Mechanize::Cookie.new(Utils.recursive_stringify_values(c))
    end
  end

end