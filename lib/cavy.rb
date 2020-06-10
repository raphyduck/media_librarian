class Cavy
  def initialize(opts = {})
    @mechanize = Mechanize.new
    @mechanize.user_agent_alias = opts['user_agent'] || "Linux Firefox"
    @mechanize.history.max_size = opts['max_history_size'] || 0
    @mechanize.history_added = Proc.new {sleep 1}
    @mechanize.pluggable_parser['application/x-bittorrent'] = Mechanize::Download
    init_capybara
  end

  def init_capybara
    @capybara = nil if defined? (@capybara) && @capybara
    @capybara = Capybara::Session.new(:poltergeist)
    #@capybara.current_window.resize_to(1900, 1000)
    @capybara.driver.headers = {'User-Agent' => @mechanize.user_agent}
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

  def reset!
    @capybara.reset!
  rescue => e
    $speaker.tell_error(e, Utils.arguments_dump(binding))
    init_capybara
  end

  private

  def get_cookies
    #@capybara.driver.browser.manage.all_cookies
    @capybara.driver.browser.cookies.map {|_, v| (Cache.object_pack(v, 1) || {})['attributes']}
  end

  def sync_cookies
    @mechanize.cookie_jar.clear!
    get_cookies.each do |c|
      # c[:expires] = DateTime.now + 1.year
      # @mechanize.cookie_jar << Mechanize::Cookie.new(Utils.recursive_stringify_values(c))
      @mechanize.cookie_jar << Mechanize::Cookie.new(
          :domain => c['domain'],
          :name => c['name'],
          :value => c['value'],
          :path => c['path'],
          :expires => c['expires']
      )
    end
  end

end