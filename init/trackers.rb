$trackers = {}
return unless File.directory?($tracker_dir)
Dir.each_child($tracker_dir) do |tracker|
  opts = YAML.load_file($tracker_dir + '/' + tracker)
  next unless opts['api_url'] && opts['api_key']
  $trackers[tracker.sub(/\.yml$/, '')] =  TorznabTracker.new(YAML.load_file($tracker_dir + '/' + tracker), tracker.sub(/\.yml$/, ''))
end