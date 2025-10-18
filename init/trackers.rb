app = MediaLibrarian.app
app.trackers = {}
return unless File.directory?(app.tracker_dir)

Dir.each_child(app.tracker_dir) do |tracker|
  file_path = File.join(app.tracker_dir, tracker)
  begin
    opts = YAML.load_file(file_path)
    next unless opts['api_url'] && opts['api_key']
    tracker_name = tracker.sub(/\.yml$/, '')
    app.trackers[tracker_name] = TorznabTracker.new(opts, tracker_name)
  rescue StandardError => e
    app.speaker.tell_error(e, Utils.arguments_dump(binding))
  end
end