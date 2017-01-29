class Config
  def self.load_settings
    $config = nil
    Dir.mkdir($config_dir) unless File.exist?($config_dir)
    unless File.exist?($config_file)
      FileUtils.copy File.dirname(__FILE__) + '/../config/conf.yml.example', $config_file
      self.reconfigure
    end
    $config = YAML.load_file($config_file) unless $config
  end

  def self.reconfigure
    $config = YAML.load_file($config_file)
    $default_conf = YAML.load_file(File.dirname(__FILE__) + '/../config/conf.yml.example')
    #Let's set the first config
    Speaker.speak_up 'The configuration file needs to be initialized.'
    if Speaker.ask_if_needed('Do you want to configure T411 authentication? (y/n)', 1, 'y') == 'y'
      $config['t411'] = {} unless $config['t411']
      Speaker.speak_up 'What is your t411 username? '
      $config['t411']['username'] = gets.strip
      $config['t411']['password'] = STDIN.getpass('What is your t411 password? ')
    elsif $config['t411'] && $config['t411'] == $default_conf['t411']
      $config.delete('t411')
    end
    if Speaker.ask_if_needed('Do you want to configure a deluge client? (y/n)', 1, 'y') == 'y'
      $config['deluge'] = {} unless $config['deluge']
      Speaker.speak_up 'What is the deluge daemon host? '
      $config['deluge']['host'] = gets.strip
      Speaker.speak_up 'What is your deluge daemon username? '
      $config['deluge']['username'] = gets.strip
      $config['deluge']['password'] = STDIN.getpass('What is your deluge daemon password? ')
    elsif $config['deluge'] && $config['deluge'] == $default_conf['deluge']
      $config.delete('deluge')
    end
    if Speaker.ask_if_needed('Do you want to configure an ImDB watchlist? (y/n)', 1, 'y') == 'y'
      $config['imdb'] = {} unless $config['imdb']
      Speaker.speak_up 'What is the imdb user (urXXXXX)? '
      $config['imdb']['user'] = gets.strip
      Speaker.speak_up 'What is your list name? '
      $config['imdb']['list'] = gets.strip
    elsif $config['imdb'] && $config['imdb'] == $default_conf['imdb']
      $config.delete('imdb')
    end
    Speaker.speak_up 'All set!'
    File.write($config_file, YAML.dump($config))
  end
end