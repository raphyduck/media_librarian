# frozen_string_literal: true

require 'yaml'
require 'date'
require 'io/console'
require_relative 'simple_speaker'

module SimpleConfigMan
  module_function

  # Keys whose values are secrets and must never be echoed to the terminal.
  SECRET_KEY_PATTERN = /password|secret|token|api[_-]?key|passcode|credential/i

  def secret_key?(key)
    key.to_s.match?(SECRET_KEY_PATTERN)
  end

  def configure_node(node, name = '', current = nil, remove_existing = 0)
    if name == '' || speaker.ask_if_needed("Do you want to configure #{name}? (y/n)", 0, 'y') == 'y'
      node.each do |key, value|
        current_value = current ? current[key] : nil
        if value.is_a?(Hash)
          node[key] = configure_node(value, [name, key].reject(&:empty?).join(' '), current_value, remove_existing)
        elsif secret_key?(key)
          node[key] = STDIN.getpass("What is your #{name} #{key}? (leave blank to keep current) ")
        else
          speaker.speak_up "What is your #{name} #{key}? [#{current_value}] "
          node[key] = STDIN.gets&.strip
        end

        node[key] = current_value if (node[key].nil? || node[key] == '') && !value.is_a?(Hash) && remove_existing == 0
      end
    else
      node = remove_existing > 0 ? nil : current
    end
    node
  end

  def load_settings(config_dir, config_file, config_example)
    Dir.mkdir(config_dir) unless File.exist?(config_dir)
    reconfigure(config_file, config_example) unless File.exist?(config_file)
    default_config = safe_load_config(config_example)
    user_config = safe_load_config(config_file)

    deep_merge(default_config, user_config)
  end

  # Config files are plain data; load them with safe_load so a crafted YAML tag
  # cannot instantiate arbitrary Ruby objects at load time.
  def safe_load_config(path)
    YAML.safe_load_file(path, permitted_classes: [Symbol, Date, Time], aliases: true) || {}
  end

  def reconfigure(config_file, config_example)
    remove_existing = 0
    config = begin
      safe_load_config(config_file)
    rescue StandardError
      remove_existing = 1
      safe_load_config(config_example)
    end

    default_config = safe_load_config(config_example)
    speaker.speak_up 'The configuration file needs to be initialized.'
    config = configure_node(default_config, '', config, remove_existing)
    speaker.speak_up 'All set!'
    File.write(config_file, YAML.dump(config))
  end

  def speaker
    @speaker ||= SimpleSpeaker::Speaker.new
  end

  def deep_merge(defaults, overrides)
    if defaults.is_a?(Hash) && overrides.is_a?(Hash)
      defaults.merge(overrides) do |_key, default_val, override_val|
        deep_merge(default_val, override_val)
      end
    else
      overrides.nil? ? defaults : overrides
    end
  end
end
