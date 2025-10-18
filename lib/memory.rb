class Memory

  def self.init_stats
    @mem ||= GetProcessMem.new
    @prev_mem ||= @mem.mb
  end

  def self.stat_do(step)
    init_stats unless defined?(@mem)
    new_mb = @mem.mb
    inc = new_mb - @prev_mem
    @stats ||= {}
    if @stats[step].nil?
      @stats[step] = {}
      @stats[step][:avg] = inc * 1024
      @stats[step][:sum] = inc * 1024
      @stats[step][:cnt] = 1
    else
      @stats[step][:avg] = (@stats[step][:sum] += inc * 1024) / (@stats[step][:cnt] += 1)
    end
    @prev_mem = new_mb
  end

  def self.stat_dump
    return unless Daemon.ensure_daemon
    $speaker.speak_up "Current total memory taken is #{@mem.mb.round(2)}MB"
    @stats.each do |step, v|
      $speaker.speak_up "For step #{step}, average increase across #{v[:cnt]} counts is #{v[:avg].round(2)}KB (total accrued is #{(v[:sum] / 1024).round(2)}MB"
    end
  end
end
