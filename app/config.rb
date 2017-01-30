class Config

  def self.configure_node(node, name = '', current = nil)
    if name == '' || Speaker.ask_if_needed("Do you want to configure #{name}? (y/n)", 0, 'y') == 'y'
      node.each do |k, v|
        curr_v = current ? current[k] : nil
        if v.is_a?(Hash)
          node[k] = self.configure_node(v, name + ' ' + k, curr_v)
        elsif ['password','client_secret'].include?(k)
          node[k] = STDIN.getpass("What is your #{name} #{k}? ")
        else
          Speaker.speak_up "What is your #{name} #{k}? [#{curr_v}] "
          node[k] = gets.strip
        end
        node[k] = curr_v if (node[k].nil? || node[k] == '') && !v.is_a?(Hash)
      end
    else
      node = current
    end
    node
  end

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
    default_config = YAML.load_file(File.dirname(__FILE__) + '/../config/conf.yml.example')
    #Let's set the first config
    Speaker.speak_up 'The configuration file needs to be initialized.'
    $config = self.configure_node(default_config, '', $config)
    Speaker.speak_up 'All set!'
    File.write($config_file, YAML.dump($config))
  end
end