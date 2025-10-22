# frozen_string_literal: true

require 'yaml'
require 'io/console'

require_relative 'simple_speaker' unless defined?(SimpleSpeaker::Speaker)

module SimpleConfigMan
  class << self
    def configure_node(node, name = '', current = nil, remove_existing = 0)
      if name.empty? || speaker.ask_if_needed("Do you want to configure #{name}? (y/n)", 0, 'y') == 'y'
        node.each do |key, value|
          current_value = current ? current[key] : nil

          if value.is_a?(Hash)
            node[key] = configure_node(
              value,
              [name, key].reject(&:empty?).join(' '),
              current_value,
              remove_existing
            )
            next
          end

          prompt = "What is your #{name} #{key}?"
          answer = if %w[password client_secret].include?(key)
                     STDIN.getpass("#{prompt} ")
                   else
                     speaker.speak_up "#{prompt} [#{current_value}] "
                     STDIN.gets&.strip
                   end

          node[key] = if answer.nil? || answer.empty?
                        current_value.nil? ? value : current_value
                      else
                        answer
                      end
        end
      else
        node = remove_existing.positive? ? nil : current
      end
      node
    end

    def load_settings(config_dir, config_file, config_example)
      Dir.mkdir(config_dir) unless File.exist?(config_dir)
      reconfigure(config_file, config_example) unless File.exist?(config_file)
      YAML.load_file(config_file)
    end

    def reconfigure(config_file, config_example)
      remove_existing = 0
      config = begin
        YAML.load_file(config_file)
      rescue StandardError
        remove_existing = 1
        YAML.load_file(config_example)
      end

      default_config = YAML.load_file(config_example)

      speaker.speak_up 'The configuration file needs to be initialized.'
      config = configure_node(default_config, '', config, remove_existing)
      speaker.speak_up 'All set!'
      File.write(config_file, YAML.dump(config))
    end

    def speaker
      @speaker ||= SimpleSpeaker::Speaker.new
    end
  end
end
