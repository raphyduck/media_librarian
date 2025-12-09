class TorrentClient
  include MediaLibrarian::AppContainerSupport

  attr_reader :app
  # Constants
  DEFAULT_SEED_TIME = 1 # hours

  # Class variables for shared state
  @@queues = { added: [], completed: [] }

  # Instance variables
  attr_reader :connected

  def initialize(app: self.class.app)
    self.class.configure(app: app)
    @app = app
    @deluge = nil
    @connected = false
    @throttled = false
  end

  def init
    Utils.lock_block("deluge_daemon_init") do
      reset_connection
      deluge
    end
  end

  def listen
    deluge.register_event('TorrentAddedEvent') do |torrent_id|
      app.speaker.speak_up "Torrent #{torrent_id} was successfully added!"
      Cache.queue_state_add_or_update('deluge_torrents_added', torrent_id) if torrent_id.to_s != ''
    end
  end

  def authenticate
    Utils.lock_block("deluge_daemon_init") do
      return if @connected
      deluge.connect
      @connected = true
      listen
    end
  end

  def delete_torrent(tname, tid = '', remove_opts = 0, delete_status = -1)
    app.t_client.remove_torrent(tid, true) if tid.to_i != 0 rescue nil
    app.db.update_rows('torrents', { :status => delete_status }, { :name => tname })
    Cache.queue_state_remove('deluge_options', tname) if remove_opts.to_i > 0
  end

  def disconnect
    reset_connection
  end

  def download_file(download, options = {}, meta_id = '')
    options.select! { |key, _| [:move_completed, :main_only].include?(key) }
    options = Utils.recursive_typify_keys(options, 0) if options.is_a?(Hash)
    if options['move_completed'].to_s != ''
      options['move_completed_path'] = options['move_completed']
      options['move_completed'] = true
    end
    options['add_paused'] = true unless download[:type] > 1
    case download[:type]
    when 1
      app.t_client.add_torrent_file(download[:filename], Base64.encode64(download[:file]), options)
      if meta_id.to_s != ''
        status = app.t_client.get_torrent_status(meta_id, ['name', 'progress', 'queue'])
        raise 'Download failed' if status.nil? || status.empty?
        app.t_client.queue_top(meta_id) if status['queue'].to_i > 1
      end
    when 2
      app.t_client.add_torrent_magnet(download[:url], options)
    when 3
      app.t_client.add_torrent_url(download[:url], options)
    end
  rescue => e
    if meta_id.to_s != '' && download.is_a?(Hash) && download[:type].to_i == 1
      status = app.t_client.get_torrent_status(meta_id, ['name', 'progress'])
      raise e if status.nil? || status.empty?
    else
      raise e
    end
  end

  def find_main_file(status, whitelisted_exts = [])
    files = {}
    status['files'].each do |file|
      if FileUtils.get_extension(file['path']).match(/r(ar|\d{2})/)
        fname = file['path'].gsub(FileUtils.get_extension(file['path']), '')
      elsif whitelisted_exts.empty? || whitelisted_exts.include?(FileUtils.get_extension(file['path']))
        fname = file['path']
      else
        app.speaker.speak_up "The file '#{file['path']}' is not on the allowed extension list (#{whitelisted_exts.join(', ')}), will not be included" if Env.debug?
        fname = 'illegalext'
      end
      files[fname] = { :s => 0, :f => [] } unless files[fname]
      files[fname][:s] += file['size'].to_i
      files[fname][:f] << file['path']
    end
    files.select { |k, f| k != 'illegalext' && f[:s] > 0.8 * status['total_size'].to_i }.map { |_, v| v[:f] }.flatten
  rescue => e
    app.speaker.tell_error(e, Utils.arguments_dump(binding))
    []
  end

  def main_file_only(status, main_files)
    priorities = []
    main_files = [main_files] unless main_files.is_a?(Array)
    status['files'].map { |f| f['path'] }.each do |f|
      priorities << (main_files.include?(f) ? 1 : 0)
    end
    { 'file_priorities' => priorities }
  end

  def parse_torrents_to_download
    queue_service.parse_pending_downloads
  end

  def process_added_torrents
    queue_service.process_added_torrents
  end

  def process_completed_torrents
    queue_service.process_completed_torrents
  end

  def process_download_torrent(torrent_name, torrent_type, path, opts, tracker = '', nodl = 0, queue_file_handling = {})
    request = MediaLibrarian::Services::TorrentDownloadRequest.new(
      torrent_name: torrent_name,
      torrent_type: torrent_type,
      path: path,
      options: opts,
      tracker: tracker,
      nodl: nodl,
      queue_file_handling: queue_file_handling
    )
    queue_service.process_download_request(request)
  end

  def rename_torrent_files(tid, files, new_dir_name, torrent_qualities = '', category = '')
    app.speaker.speak_up("Will move all files in torrent in a directory '#{new_dir_name}', ensuring qualities #{torrent_qualities} in the filenames") if new_dir_name.to_s != ''
    paths = []
    files.each do |file|
      old_name = Quality.filename_quality_change(File.basename(file['path']), torrent_qualities, [], category)
      new_path = "#{new_dir_name.to_s + '/' if new_dir_name.to_s != ''}#{StringUtils.fix_encoding(old_name)}"
      paths << [file['index'], new_path]
    end
    app.t_client.rename_files(tid, paths)
  end

  def queue_service
    @queue_service ||= MediaLibrarian::Services::TorrentQueueService.new(app: app, client: self)
  end

  def self.check_orphaned_torrent_folders(completed_folder:)
    ff = FileUtils.search_folder(completed_folder, { 'maxdepth' => 1, 'dironly' => 1 }).map { |f| File.basename(f[0]) }
    tids = app.t_client.get_session_state
    tids.each do |tid|
      status = app.t_client.get_torrent_status(tid, ['name', 'state'])
      ff.delete(status['name'])
    end
    ff.each do |f|
      app.speaker.speak_up "Warning, folder '#{f}' is orphaned, will be removed"
      FileUtils.rm_r("#{completed_folder}/#{f}")
    end
  end

  def self.flush_queues
    if app.t_client
      app.t_client.parse_torrents_to_download
      sleep 15
      app.t_client.process_added_torrents
      app.t_client.process_completed_torrents
      #app.t_client.disconnect
    end
  end

  def self.get_config(client, key)
    app.config[client][key] rescue nil
  end

  def self.monitor_torrent_client
    app.speaker.speak_up("Checking free space remaining on torrent server", 0)
    free_space_bytes = app.t_client.get_free_space
    free_space = free_space_bytes.to_f / 1024 / 1024 / 1024
    app.speaker.speak_up("Free space remaining: #{free_space}GB", 0)
    if free_space <= get_config('deluge', 'min_torrent_free_space').to_i && !@throttled
      app.speaker.speak_up "There is only #{free_space}GB of free space on torrent server, will throttle download rate now!"
      app.t_client.set_config([{ 'config' => { 'max_download_speed' => [get_config('deluge', 'max_download_rate').to_i / 100, 10].max } }])
      @throttled = true
    elsif @throttled && free_space > get_config('deluge', 'min_torrent_free_space').to_i
      app.speaker.speak_up "There is now enoough free space on torrent server, restoring full download speed!"
      app.t_client.set_config([{ 'config' => { 'max_download_speed' => get_config('deluge', 'max_download_rate') || 1000 } }]) # todo: better fix than putting in brackets
      @throttled = false
    end
  end

  def self.no_delete_torrent(name: '', tid: '')
    return app.speaker.speak_up "No torrent name or id provided!" if name.to_s == '' && tid.to_s == ''
    app.speaker.speak_up "Torrent identified by #{{ 'name' => name, 'tid' => tid }.map { |k, v| k.to_s + ' = ' + v.to_s }.join(' and ')} will not be deleted"
    app.db.update_rows('torrents', { :status => 5 }, { :name => name.to_s }) if name.to_s != ''
    app.db.update_rows('torrents', { :status => 5 }, { :torrent_id => tid.to_s })
  end

  def method_missing(name, *args)
    tries = 3
    sanitized_args = StringUtils.accents_clear(args)
    debug_message = build_debug_message(name, sanitized_args)

    log_operation(debug_message)
    return if skip_operation?(name)

    safely_execute_deluge_operation(name, sanitized_args, debug_message, tries)
  rescue => e
    app.speaker.tell_error(e, "app.t_client.#{debug_message}")
    raise e unless invalid_torrent_error?(e)
  end

  private

  def build_debug_message(name, args)
    args_display = args.empty? ? "" : "(" + args.map { |a| DataUtils.format_string(a.to_s[0..100]) }.join(',') + ")"
    "#{name}#{args_display}"
  end

  def log_operation(debug_message)
    app.speaker.speak_up("Running app.t_client.#{debug_message}", 0) if Env.debug?
  end

  def skip_operation?(name)
    Env.pretend? && !['get_torrent_status'].include?(name)
  end

  def safely_execute_deluge_operation(name, args, debug_message, tries_remaining)
    Timeout.timeout(60) do
      authenticate
      core = deluge.core
      args.empty? ? core.send(name) : core.send(name, *args)
    end
  rescue => e
    return handle_invalid_torrent(args) if invalid_torrent_error?(e)

    reset_connection
    if tries_remaining > 1
      sleep 5
      safely_execute_deluge_operation(name, args, debug_message, tries_remaining - 1)
    else
      app.speaker.tell_error(e, "app.t_client.#{debug_message}")
      raise e
    end
  end

  def invalid_torrent_error?(error)
    [error.class.to_s, error.message.to_s].any? { |msg| msg.include?('InvalidTorrentError') }
  end

  def handle_invalid_torrent(args)
    tid = Array(args.first).first.to_s
    return {} if tid.empty?

    Cache.queue_state_remove('deluge_torrents_added', tid)
    Cache.queue_state_remove('deluge_torrents_completed', tid)
    {}
  end

  def reset_connection
    @connected = false
    @deluge&.close rescue nil
    @deluge = nil
  end

  def deluge
    @deluge ||= Deluge::Rpc::Client.new(
      host: app.config['deluge']['host'],
      port: 58846,
      login: app.config['deluge']['username'],
      password: app.config['deluge']['password']
    )
  end

end
