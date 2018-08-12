class DataUtils

  def self.dump_variable(val, max_depth = 2, start = 0, new_line = 1)
    nl = new_line.to_i > 0 ? "\n" : ''
    dump = ''
    val = Cache.object_pack(val, 1)
    if max_depth <= 0
      dump << "#{'  ' * start * new_line}<#{[Vash,Hash,Array].include?(val.class) ? val.count : 1} element(s)>#{nl}"
    else
      if val.is_a?(Hash)
        hs = []
        val.each do |k, v|
          hs << "#{k.is_a?(Symbol) ? ':' : '\''}#{k}#{'\'' unless k.is_a?(Symbol)}=>#{nl}#{dump_variable(v, max_depth - 1, start + 1, new_line)}"
        end
        dump << "#{'  ' * start * new_line}{#{nl}#{hs.join(', ')}#{'  ' * start * new_line}}#{nl}"
      elsif val.is_a?(Array)
        dump << "#{'  ' * start * new_line}[#{nl}"
        dump << val.map {|v| dump_variable(v, max_depth - 1, start + 1, new_line)}. join(', ')
        dump << "#{'  ' * start * new_line}]#{nl}"
      else
        dump << "#{'  ' * start * new_line}#{val}#{nl}"
      end
    end
    dump
  end
end