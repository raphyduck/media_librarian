# frozen_string_literal: true

# YAML file/directory HTTP endpoints for the daemon control server: listing a
# directory of .yml files, reading/writing a single file (with path traversal
# guards), and config-secret redaction so secrets are never served to the UI
# nor overwritten by the redaction placeholder on save. Reopens Daemon's
# singleton class so these methods stay byte-for-byte identical to their prior
# inline definitions; extracted purely to shrink app/daemon.rb. Zeitwerk is
# told to ignore this file (see Application#setup_loader) because it reopens
# Daemon rather than defining a Daemon::FileEndpoints constant.

class Daemon
  class << self
    def handle_directory_request(req, res, base_path, directory, mutex, after_save: nil)
      if req.path == base_path
        return method_not_allowed(res, 'GET') unless req.request_method == 'GET'

        files = mutex.synchronize do
          if File.directory?(directory)
            Dir.children(directory).select do |entry|
              entry.end_with?('.yml') && File.file?(File.join(directory, entry))
            end.sort
          else
            []
          end
        end

        return json_response(res, body: { 'files' => files })
      end

      unless req.path.start_with?("#{base_path}/")
        return error_response(res, status: 404, message: 'not_found')
      end

      return method_not_allowed(res, 'GET, PUT') unless %w[GET PUT].include?(req.request_method)

      path = sanitize_yaml_path(req.path, base_path, directory)
      return error_response(res, status: 404, message: 'not_found') unless path

      handle_file_request(req, res, path, mutex, 'GET, PUT', after_save: after_save)
    end

    def handle_file_request(req, res, path, mutex, allowed_methods, redact_secrets: false, after_save: nil)
      case req.request_method
      when 'GET'
        content = mutex.synchronize { File.exist?(path) ? File.read(path) : nil }
        content = redact_config_content(content) if redact_secrets && content
        json_response(res, body: { 'content' => content })
      when 'PUT'
        begin
          payload = parse_payload(req)
        rescue JSON::ParserError => e
          return error_response(res, status: 422, message: e.message)
        end

        unless payload.key?('content')
          return error_response(res, status: 422, message: 'missing_content')
        end

        content = payload['content']
        unless content.is_a?(String)
          return error_response(res, status: 422, message: 'invalid_content')
        end

        # Restore any secret left as the redaction placeholder (the GET masks
        # them) from the on-disk file, so editing/saving never wipes secrets the
        # client was never shown.
        if redact_secrets
          existing = mutex.synchronize { File.exist?(path) ? File.read(path) : '' }
          content = restore_redacted_config(content, existing)
        end

        begin
          validate_yaml(content)
        rescue Psych::SyntaxError => e
          return error_response(res, status: 422, message: e.message)
        end

        mutex.synchronize do
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, content)
        end

        begin
          after_save&.call
        rescue StandardError => e
          return error_response(res, status: 500, message: e.message)
        end

        json_response(res, status: 204)
      else
        method_not_allowed(res, allowed_methods)
      end
    end

    def sensitive_config_leaf?(key)
      SENSITIVE_CONFIG_LEAVES.include?(key.to_s.downcase)
    end

    # Mask secret values in a YAML config text while preserving comments,
    # indentation and everything else (line-based, not a re-dump).
    def redact_config_content(content)
      content.to_s.each_line.map do |line|
        match = line.match(/\A(\s*)([\w-]+)(\s*:\s*)(\S[^\n]*?)([ \t]*\R?)\z/)
        next line unless match && sensitive_config_leaf?(match[2])
        next line if match[4].start_with?('|', '>', '&', '*') # block scalars / anchors

        "#{match[1]}#{match[2]}#{match[3]}#{CONFIG_REDACTION_PLACEHOLDER}#{match[5]}"
      end.join
    end

    # On save, swap any secret still set to the placeholder back to the stored
    # value, matched by full key path so same-named keys in different sections
    # (e.g. deluge.password vs email.password) never get cross-wired.
    def restore_redacted_config(new_content, existing_content)
      existing = config_secret_values(existing_content)
      stack = []
      new_content.to_s.each_line.map do |line|
        stripped = line.strip
        next line if stripped.empty? || stripped.start_with?('#')

        match = line.match(/\A(\s*)([\w-]+)(\s*:\s*)(.*?)([ \t]*\R?)\z/)
        next line unless match

        indent = match[1].length
        stack.pop while stack.any? && stack.last[0] >= indent
        key = match[2]
        value = match[4]
        if value.empty?
          stack.push([indent, key])
          next line
        end
        if sensitive_config_leaf?(key) && value == CONFIG_REDACTION_PLACEHOLDER
          path = (stack.map { |entry| entry[1] } + [key]).join('.')
          original = existing[path]
          next(original ? "#{match[1]}#{match[2]}#{match[3]}#{original}#{match[5]}" : line)
        end
        line
      end.join
    end

    def config_secret_values(content)
      values = {}
      stack = []
      content.to_s.each_line do |line|
        stripped = line.strip
        next if stripped.empty? || stripped.start_with?('#')

        match = line.match(/\A(\s*)([\w-]+)\s*:\s*(.*?)[ \t]*\R?\z/)
        next unless match

        indent = match[1].length
        stack.pop while stack.any? && stack.last[0] >= indent
        key = match[2]
        value = match[3]
        if value.empty?
          stack.push([indent, key])
        elsif sensitive_config_leaf?(key)
          path = (stack.map { |entry| entry[1] } + [key]).join('.')
          values[path] = value
        end
      end
      values
    end

    def sanitize_yaml_path(request_path, base_path, directory)
      relative = request_path.sub(%r{^#{Regexp.escape(base_path)}/}, '')
      return if relative.empty?

      begin
        decoded = WEBrick::HTTPUtils.unescape(relative)
      rescue ArgumentError
        return
      end

      return unless decoded.end_with?('.yml')

      basename = File.basename(decoded)
      return unless basename == decoded

      File.join(directory, basename)
    end
  end
end
