require_relative 'simple_speaker'
require 'yaml'
require 'date'

module SimpleArgsDispatch
  class Agent

    # Actions will be in the following format:
    #   {
    #       :help => ['Dispatcher', 'show_available'],
    #       :reconfigure => ['App', 'reconfigure'],
    #       :some_name => {
    #           :some_function => ['SomeName', 'SomeFunction'],
    #           .....
    #   }
    # end

    def initialize(speaker = nil, env_variables = {})
      @speaker = speaker
      @env_variables = env_variables
    end

    def dispatch(app_name, args, actions, parent = nil, template_dir = '', descriptions = {})
      arg = args.shift
      actions.each do |k, v|
        if arg == k.to_s
          if v.is_a?(Hash)
            self.dispatch(app_name, args, v, "#{parent} #{arg}", template_dir, descriptions)
          else
            self.launch(app_name, v, args, "#{parent} #{arg}", template_dir)
          end
          return
        end
      end
      message = arg.nil? ? 'Missing command/option' : "Unknown command/option '#{arg}'"
      suggestion = nearest_command(arg, actions.keys.map(&:to_s))
      message += ". Did you mean '#{suggestion}'?" if suggestion
      @speaker.speak_up("#{message}\n\n")
      self.show_available(app_name, actions, parent, descriptions: descriptions)
    end

    def launch(app_name, action, args, parent, template_dir)
      args = Hash[args.flat_map { |s| s.scan(/--?([^=\s]+)(?:=(.+))?/) }]
      template_args = parse_template_args(load_template(args['template_name'], template_dir), template_dir)
      model = Object.const_get(action[0])
      req_params = model.method(action[1].to_sym).parameters.map { |a| a.reverse! }
      req_params.each do |param|
        return self.show_available(app_name, Hash[req_params.map { |k| ["--#{k[0]}=<#{k[0]}>", k[1]] }], parent, ' ', new_line, "Missing parameter: '#{param[0]}'") if param[1] == :keyreq && args[param[0].to_s].nil? && template_args[param[0].to_s].nil?
      end
      set_env_variables(@env_variables, args, template_args)
      dameth = model.method(action[1])
      params = Hash[req_params.map do |k, _|
        val = args[k.to_s] || template_args[k.to_s]
        # Parse `{...}`/`[...]` argument values into data structures, but via
        # safe_load so a crafted value (e.g. !ruby/object) cannot instantiate
        # arbitrary Ruby objects (these args can originate from HTTP callers).
        val = YAML.safe_load(val.gsub('=>', ': '), permitted_classes: [Symbol], aliases: false) if val.is_a?(String) && val.match(/^[{\[].*[}\]]$/)
        [k, val]
      end].select { |_, v| !v.nil? }
      if Thread.current[:debug].to_i > 0
        @speaker.speak_up("Running with arguments: #{params}", 0)
      end
      params.empty? ? dameth.call : dameth.call(**params)
    end

    def load_template(template_name, template_dir)
      if template_name.to_s != '' && File.exist?(template_dir + '/' + "#{template_name}.yml")
        return YAML.safe_load_file(template_dir + '/' + "#{template_name}.yml", permitted_classes: [Symbol, Date, Time], aliases: true)
      end
      {}
    rescue
      {}
    end

    def new_line
      '---------------------------------------------------------'
    end

    def parse_template_args(template, template_dir)
      template.keys.each do |k|
        if k.to_s == 'load_template'
          template[k] = [template[k]] if template[k].is_a?(String)
          template[k].each do |t|
            template.merge!(parse_template_args(load_template(t.to_s, template_dir), template_dir))
          end
          template.delete(k)
        elsif template[k].is_a?(Hash)
          template[k] = parse_template_args(template[k], template_dir)
        end
      end
      template
    end

    def set_env_variables(env_flags, args, template_args = {})
      env_flags.each do |k, _|
        Thread.current[k] = (args[k.to_s] || template_args[k.to_s]).to_i if args[k.to_s] || template_args[k.to_s]
      end
    end

    def show_available(app_name, available, prepend = nil, join='|', separator = new_line, extra_info = '', descriptions: {})
      entries = available.is_a?(Hash) ? available.to_a : (available ? Array(available) : [])
      display = entries.map do |item|
        key, flag = Array(item).values_at(0, 1)
        key = key.to_s
        flag == :key ? "[#{key}]" : key
      end.join(join)
      @speaker.speak_up("Usage: #{app_name} #{prepend + ' ' if prepend}#{display}")
      unless descriptions.nil? || descriptions.empty?
        keys = entries.map { |item| Array(item).first.to_s }
        width = keys.map(&:length).max.to_i
        described = keys.filter_map do |key|
          path = [prepend, key].map { |part| part.to_s.strip }.reject(&:empty?).join(' ')
          desc = descriptions[path]
          "  #{key.ljust(width)}  #{desc}" if desc
        end
        unless described.empty?
          @speaker.speak_up('')
          described.each { |line| @speaker.speak_up(line) }
        end
      end
      if extra_info.to_s != ''
        @speaker.speak_up(separator)
        @speaker.speak_up(extra_info)
      end
    end

    # Closest command name to +arg+ among +keys+ by edit distance, used to offer
    # a "did you mean" suggestion. Returns nil when nothing is close enough.
    def nearest_command(arg, keys)
      arg = arg.to_s
      return nil if arg.empty? || keys.empty?

      best = keys.min_by { |key| levenshtein(arg, key) }
      return nil unless best

      distance = levenshtein(arg, best)
      threshold = [3, (best.length / 2.0).ceil].max
      distance <= threshold ? best : nil
    end

    def levenshtein(first, second)
      first = first.to_s
      second = second.to_s
      return second.length if first.empty?
      return first.length if second.empty?

      row = (0..second.length).to_a
      first.each_char.with_index(1) do |char_a, i|
        previous = row[0]
        row[0] = i
        second.each_char.with_index(1) do |char_b, j|
          current = row[j]
          row[j] = [row[j] + 1, row[j - 1] + 1, previous + (char_a == char_b ? 0 : 1)].min
          previous = current
        end
      end
      row[second.length]
    end
  end
end
