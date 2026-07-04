# frozen_string_literal: true

# Command-catalog serialization for the daemon's /commands and
# /template_commands endpoints: turning the command registry and the scheduler
# template files into the nested command tree the web UI's command palette
# consumes. Reopens Daemon's singleton class so these methods stay byte-for-byte
# identical to their prior inline definitions; extracted purely to shrink
# app/daemon.rb. Zeitwerk is told to ignore this file (see
# Application#setup_loader) because it reopens Daemon rather than defining a
# Daemon::CommandCatalog constant.

class Daemon
  class << self
    def serialize_commands(actions, prefix = [])
      return [] unless actions.is_a?(Hash)

      actions.flat_map do |name, action|
        current = prefix + [name.to_s]
        if action.is_a?(Hash)
          serialize_commands(action, current)
        else
          build_command_entry(action, current)
        end
      end.compact
    end

    def build_command_entry(action, command_path)
      args = command_arguments(action)
      queue = command_queue(action)
      entry = { 'name' => command_path.join(' '), 'command' => command_path, 'args' => args }
      entry['queue'] = queue if queue
      entry
    rescue StandardError
      nil
    end

    def command_arguments(action)
      class_name, method_name = Array(action)
      return [] unless class_name && method_name

      target = Object.const_get(class_name)
      method = target.method(method_name)
      method.parameters.filter_map do |type, name|
        next unless name

        { 'name' => name.to_s, 'required' => %i[req keyreq].include?(type), 'kind' => type.to_s }
      end
    rescue StandardError
      []
    end

    def command_queue(action)
      config = Array(action).drop(2)
      queue = config[1]
      queue if queue.is_a?(String) && !queue.empty?
    end

    def build_template_commands
      template_directories.flat_map do |directory|
        Dir.glob(File.join(directory, '*.yml')).flat_map do |path|
          template_file_commands(path, directory)
        end
      end.compact
    end

    def template_file_commands(path, directory)
      template = YAML.safe_load(File.read(path), aliases: true)
      return [] unless template.is_a?(Hash) || template.is_a?(Array)

      base_name = File.basename(path, '.yml')
      nodes = if template.is_a?(Array)
                template.flat_map do |item|
                  item.is_a?(Hash) ? template_command_nodes(item, base_name) : []
                end
              else
                template_command_nodes(template, base_name)
              end
      nodes.filter_map do |entry|
        build_template_command_entry(entry[:name], entry[:data], directory)
      end
    rescue Psych::SyntaxError => e
      app.speaker.tell_error(e, "Invalid template at #{path}")
      []
    end

    def template_command_nodes(template, fallback_name)
      return [] unless template.is_a?(Hash)

      nodes = []
      nodes << { name: fallback_name, data: template } if command_hash?(template)

      template.each do |key, value|
        case value
        when Hash
          nodes.concat(template_command_nodes(value, key))
        when Array
          value.each do |item|
            nodes.concat(template_command_nodes(item, fallback_name)) if item.is_a?(Hash)
          end
        end
      end

      nodes
    end

    def command_hash?(data)
      data.key?('command') || data.key?(:command)
    end

    def build_template_command_entry(name, data, template_dir)
      return unless data.is_a?(Hash)

      command_parts = normalize_command_parts(data['command'] || data[:command])
      return if command_parts.empty?

      action = find_command_action(command_parts.dup)
      entry = {
        'name' => name.to_s,
        'command' => command_parts,
        'args' => command_arguments(action)
      }
      arg_values = template_command_arg_values(data, template_dir)
      entry['arg_values'] = arg_values if arg_values&.any?
      template_args = template_command_arg_keys(data, template_dir)
      if arg_values&.any?
        template_args = (template_args + arg_values.keys).map(&:to_s).uniq
      end
      entry['template_args'] = template_args if template_args&.any?
      queue = template_command_queue(data, action)
      entry['queue'] = queue if queue
      entry
    end
  end
end
