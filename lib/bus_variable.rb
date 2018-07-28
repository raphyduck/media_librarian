require File.dirname(__FILE__) + '/library_bus'
require File.dirname(__FILE__) + '/utils'
class BusVariable
  attr_accessor :value

  def initialize(vname, type = Vash)
    @vname = vname
    Utils.lock_block("bus_variable_#{@vname}") do
      @value = LibraryBus.bus_variable_get(vname) || type.new
      LibraryBus.bus_variable_set(vname, @value) if LibraryBus.bus_variable_get(vname).nil?
    end
  end

  def [](key)
    get_hash[key]
  end

  def []=(key, *args)
    key = [key]
    key += args[0..-2] if args.length > 1
    Utils.lock_block("bus_variable_#{@vname}") do
      h = get_hash
      h[*key] = args[-1]
      LibraryBus.bus_variable_set(@vname, h)
      @value = LibraryBus.bus_variable_get(@vname)
    end
  end

  def method_missing(name, *args, &block)
    Utils.lock_block("bus_variable_#{@vname}") do
      if args.empty?
        value.method(name).call(&block)
      else
        value.method(name).call(*args, &block)
      end
    end
  end

  def self.add_bus_variables(vname, thread)
    LibraryBus.bus_get(thread, 1)[:bus_vars] = [] unless LibraryBus.bus_get(thread, 1)[:bus_vars]
    LibraryBus.bus_get(thread, 1)[:bus_vars] << vname unless LibraryBus.bus_get(thread, 1)[:bus_vars].include?(vname)
  end

  def self.display_bus_variable(variable_name:, max_depth: 2)
    $speaker.speak_up("Dump of bus variable '#{variable_name}'")
    $speaker.speak_up DataUtils.dump_variable(BusVariable.new(variable_name).value, max_depth.to_i)
  end

  def self.list_bus_variables
    LibraryBus.bus_get(Thread.current, 1)[:bus_vars] || []
  end

  def self.remove_bus_variables(vname, thread)
    LibraryBus.bus_get(thread, 1)[:bus_vars].delete(vname) if LibraryBus.bus_get(thread, 1)[:bus_vars].is_a?(Array)
  end

  private

  def get_hash
    return nil unless value.is_a?(Hash)
    value
  end
end