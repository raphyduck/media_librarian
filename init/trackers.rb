$trackers = {}
return unless File.directory?($tracker_dir)

Dir.each_child($tracker_dir) do |tracker|
  file_path = File.join($tracker_dir, tracker)
  begin
    opts = YAML.load_file(file_path)
    next unless opts['api_url'] && opts['api_key']
    tracker_name = tracker.sub(/\.yml$/, '')
    $trackers[tracker_name] = TorznabTracker.new(opts, tracker_name)
  rescue StandardError => e
    $speaker.tell_error(e, Utils.arguments_dump(binding))
  end
end