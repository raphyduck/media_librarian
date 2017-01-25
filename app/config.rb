class Config
  def self.load_settings
    $config = nil
    Dir.mkdir($config_dir) unless File.exist?($config_dir)
    unless File.exist?($config_file)
      FileUtils.copy File.dirname(__FILE__) + '/config/conf.yml.example', $config_file
      self.reconfigure
    end
    $config = YAML.load_file($config_file) unless $config
  end

  def self.reconfigure
    $config = YAML.load_file($config_file)
    #Let's set the first config
    puts 'The configuration file needs to be initialized.'
    puts 'Do you want to configure T411 authentication? (y/n)'
    reply = gets.strip
    if reply == 'y'
      $config['t411'] = {} unless $config['t411']
      Speaker.speak_up 'What is your t411 username? '
      $config['t411']['username'] = gets.strip
      $config['t411']['password'] = STDIN.getpass('What is your t411 password? ')
    else
      $config.delete('t411')
    end
    puts 'Do you want to say a deluge client? (y/n)'
    reply = gets.strip
    if reply == 'y'
      $config['deluge'] = {} unless $config['deluge']
      Speaker.speak_up 'What is the deluge daemon host? '
      $config['deluge']['host'] = gets.strip
      Speaker.speak_up 'What is your deluge daemon username? '
      $config['deluge']['username'] = gets.strip
      $config['deluge']['password'] = STDIN.getpass('What is your deluge daemon password? ')
    else
      $config.delete('deluge')
    end
    Speaker.speak_up 'All set!'
    File.write($config_file, YAML.dump($config))
  end
end