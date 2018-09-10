module ExecutionHooks

  def self.alias_hook(sym)
    "__#{sym}__hooked__"
  end

  def self.on_the_fly_hooking(classes)
    classes.each do |k|
      Object.const_get(k).class_eval do
        Class.send(:include, ExecutionHooks)
        class << self
          before_hook do |bds, class_name, method_name|
            $speaker.speak_up Utils.arguments_dump(bds, 1, class_name, method_name) if Env.debug?
          end
        end
      end
    end
  end

  private

  # Hook the provided instance methods so that the block
  # is executed directly after the specified methods have
  # been invoked.
  #
  def before_hook(&block)
    public_instance_methods(false).each do |sym| # For each symbol
      str_id = ExecutionHooks.alias_hook(sym)
      alias_method str_id, sym rescue next # Backup original
      # method
      private str_id # Make backup private
      define_method sym do |*args| # Replace method
        block.call(args, self.name, sym)
        __send__ str_id, *args # Invoke backup
      end
    end
  end
end