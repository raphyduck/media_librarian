class Hash

  def +(h)
    h.keys.each do |k|
      if key?(k) && [Array, Hash, Vash].include?(h[k].class) && [Array, Hash, Vash].include?(values_at(k).first.class)
        begin
          h[k] += values_at(k).first
        rescue
        end
      end
    end
    merge(h)
  end
end