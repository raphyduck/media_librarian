class DataUtils

  def self.dump_variable(val, max_depth = 2, start = 0, new_line = 1, max_nb_keys = 10)
    nl = new_line.to_i > 0 ? "\n" : ''
    dump = ''
    val = Cache.object_pack(val, 1)
    if max_depth <= 0
      dump << "#{'  ' * start * new_line}<#{[Vash, Hash, Array].include?(val.class) ? val.count : 1} element(s)>#{nl}"
    else
      if val.is_a?(Hash)
        hs, knb = [], 0
        val.each do |k, v|
          break if (knb += 1) > max_nb_keys.to_i
          hs << "#{k.is_a?(Symbol) ? ':' : '\''}#{k}#{'\'' unless k.is_a?(Symbol)}=>#{nl}#{dump_variable(v, max_depth - 1, start + 1, new_line)}"
        end
        dump << "#{'  ' * start * new_line}{#{nl}#{hs.join(', ')}#{'  ' * start * new_line}}#{nl}"
      elsif val.is_a?(Array)
        dump << "#{'  ' * start * new_line}[#{nl}"
        dump << val[0..(max_nb_keys - 1)].map { |v| dump_variable(v, max_depth - 1, start + 1, new_line) }.join(', ')
        dump << "#{'  ' * start * new_line}]#{nl}"
      else
        dump << "#{'  ' * start * new_line}#{format_string(val)}#{nl}"
      end
    end
    dump
  end

  def self.format_string(obj)
    case obj
    when nil then 'nil'
    when String then "'#{obj}'"
    when Array then obj.map { |x| format_string(x) }
    when Hash then obj.transform_values { |v| format_string(v) }
    else obj.to_s
    end
  end
end