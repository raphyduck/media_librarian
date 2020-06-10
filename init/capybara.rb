require 'capybara'
#require 'selenium/webdriver'
require 'capybara/poltergeist'
Capybara.run_server = false
Capybara.register_driver :poltergeist do |app|
  Capybara::Poltergeist::Driver.new(app, js_errors: false, debug: false)
end

# Configure Capybara to use Poltergeist as the driver
Capybara.default_driver = :poltergeist
#Capybara.ignore_hidden_elements = true
# Capybara.register_driver :headless_chrome do |app|
#   Capybara::Selenium::Driver.load_selenium
#   browser_options = ::Selenium::WebDriver::Chrome::Options.new.tap do |opts|
#     opts.args << '--headless'
#     opts.args << '--disable-gpu' if Gem.win_platform?
#     # Workaround https://bugs.chromium.org/p/chromedriver/issues/detail?id=2650&q=load&sort=-id&colspec=ID%20Status%20Pri%20Owner%20Summary
#     opts.args << '--disable-site-isolation-trials'
#     opts.args << '--disable-dev-shm-usage' #See https://stackoverflow.com/questions/50642308/webdriverexception-unknown-error-devtoolsactiveport-file-doesnt-exist-while-t
#     opts.args << "--user-agent='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/81.0.4044.113 Safari/537.36'"
#   end
#   Capybara::Selenium::Driver.new(app, browser: :chrome, options: browser_options)
# end
# Capybara.default_driver = :headless_chrome