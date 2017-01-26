class Dispatcher

  def self.available_actions
    {
        :help => ['Dispatcher', 'show_available'],
        :reconfigure => ['Config', 'reconfigure'],
        :library => {
            :replace_movies => ['Library', 'replace_movies']
        },
        :t411 => {
            :search => ['T411Search', 'search']
        },
        :usage => ['Dispatcher', 'show_available']
    }
  end

  def self.dispatch(args, actions = self.available_actions, parent = nil)
    arg = args.shift
    actions.each do |k, v|
      if arg == k.to_s
        if v.is_a?(Hash)
          self.dispatch(args, v, arg)
        else
          self.launch(v, args)
        end
        return
      end
    end
    Speaker.speak_up('Unknown command/option')
    self.show_available(actions, parent)
  end

  def self.launch(action, args)
    dameth = Object.const_get(action[0]).method(action[1])
    dameth.call(*args)
  rescue => e
    Speaker.tell_error(e, "Dispatcher.launch")
  end

  def self.show_available(available = self.available_actions, prepend = nil)
    Speaker.speak_up("Usage: ruby librarian.rb #{prepend + ' ' if prepend}#{available.map{|k, _| k.to_s}}")
  end
end