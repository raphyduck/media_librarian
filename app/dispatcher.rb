class Dispatcher

  def self.available_actions
    {
        :help => ['Dispatcher', 'show_available'],
        :reconfigure => ['Config', 'reconfigure'],
        :library => {
            :replace_movies => ['Library', 'replace_movies'],
            :compare_remote_files => ['Library', 'compare_remote_files']
        },
        :torrent => {
            :search => ['TorrentSearch', 'search']
        },
        :usage => ['Dispatcher', 'show_available']
    }
  end

  def self.dispatch(args, actions = self.available_actions, parent = nil)
    arg = args.shift
    actions.each do |k, v|
      if arg == k.to_s
        if v.is_a?(Hash)
          self.dispatch(args, v, "#{parent} #{arg}")
        else
          self.launch(v, args, "#{parent} #{arg}")
        end
        return
      end
    end
    Speaker.speak_up('Unknown command/option

')
    self.show_available(actions, parent)
  end

  def self.launch(action, args, parent)
    args = Hash[ args.flat_map{|s| s.scan(/--?([^=\s]+)(?:=(.+))?/) } ]
    model = Object.const_get(action[0])
    req_params = model.method(action[1].to_sym).parameters.map {|a| a.reverse!}
    req_params.each do |param|
      return self.show_available(Hash[req_params.map{|k| ["--#{k[0]}=<#{k[0]}>", k[1]]}], parent, ' ') if param[1] == :req && args[param[0].to_s].nil?
    end
    dameth = model.method(action[1])
    dameth.call(*req_params.map{|k, _| args[k.to_s]})
  rescue => e
    Speaker.tell_error(e, "Dispatcher.launch")
  end

  def self.show_available(available = self.available_actions, prepend = nil, join='|')
    Speaker.speak_up("Usage: librarian #{prepend + ' ' if prepend}#{available.map{|k, v| "#{k.to_s}#{'(optional)' if v == :opt}"}.join(join)}")
  end
end