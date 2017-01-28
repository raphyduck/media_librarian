class TorrentClient

  def initialize()
    @deluge = Deluge::Rpc::Client.new(
        host: $config['deluge']['host'], port: 58846,
        login: $config['deluge']['username'], password: $config['deluge']['password']
    )
  rescue => e
    Speaker.tell_error(e, "TorrentClient.new")
    raise
  end

  def authenticate
    return if @deluge_connected
    @deluge.connect
    @deluge_connected = 1
    listen
  end

  def disconnect
    @deluge.close
    @deluge_connected = nil
  end

  def download(url, move_completed = nil)
    authenticate unless @deluge_connected
    options = {}
    if move_completed
      options['move_completed_path'] = move_completed
      options['move_completed'] = true
    end
    @deluge.core.add_torrent_url(url, options.to_json)
  end

  def download_file(file, filename, move_completed = nil)
    self.authenticate unless @deluge_connected
    options = {}
    if move_completed && move_completed != ''
      options['move_completed_path'] = move_completed
      options['move_completed'] = true
    end
    @deluge.core.add_torrent_file(filename, Base64.encode64(file), options) rescue Deluge::Rpc::Connection::InvokeTimeoutError
  end

  def find_main_file(status)
    status['files'].each do |file|
      if file['size'].to_i > (status['total_size'].to_i * 0.9)
        return file
      end
    end
    return nil
  rescue => e
    Speaker.tell_error(e, "torrentclient.find_main_file")
  end

  def listen
    @deluge.register_event('TorrentAddedEvent') do |torrent_id|
      Speaker.speak_up "Torrent #{torrent_id} was successfully added!"
      $deluge_torrents_added << torrent_id
    end
  end

  def main_file_only(status, main_file)
    priorities = []
    status['files'].each do |f|
      priorities << (f == main_file ? 1 : 0)
    end
    {'file_priorities' => priorities}
  end

  def process_added_torrents
    while $deluge_torrents_added.length != 0
      tid = $deluge_torrents_added.shift
      status = @deluge.core.get_torrent_status(tid, ['name', 'files', 'total_size','progress'])
      opts = $deluge_options.select{|_,v| v['t_name'] == status['name']}
      if opts.nil? || opts.empty?
        closeness = FuzzyStringMatch::JaroWinkler.create( :pure )
        opts = $deluge_options.select{|_,v| closeness.getDistance(v['t_name'][0..30], status['name'][0..30]) > 0.9}
      end
      if opts && !opts.empty?
        did = opts.first[0]
        opts = opts.first[1]
        set_options = {}
        File.delete($temp_dir + "/#{did}.torrent") rescue nil
        if (opts['rename_main'] && opts['rename_main'] != '') || (opts['main_only'] && opts['main_only'] > 0)
          main_file = find_main_file(status)
          if main_file
            set_options = main_file_only(status, main_file) if opts['main_only']
            rename_main_file(tid, status['files'], opts['rename_main'])
          end
        end
        unless set_options.empty?
          @deluge.core.set_torrent_options([tid], set_options)
          Speaker.speak_up("Will set options: #{set_options}")
        end
        $deluge_options.delete(did)
      end
    end
  end

  def process_download_torrents
    Speaker.speak_up("Downloading torrent(s) added during the session (if any)")
    Find.find($temp_dir).each do |path|
      unless FileTest.directory?(path)
        if path.end_with?('torrent')
          file = File.open(path, "r")
          torrent = file.read
          file.close
          opts = $deluge_options[File.basename(path).gsub('.torrent', '')]
          download_file(torrent, File.basename(path), opts['move_completed']) unless opts.nil?
        end
      end
    end
  end

  def rename_main_file(tid, files, new_dir_name)
    Speaker.speak_up("Will move all files in torrent in a 'directory #{new_dir_name}'.")
    paths = []
    files.each do |file|
      old_name = File.basename(file['path'])
      new_path = new_dir_name + '/' + old_name
      paths << [file['index'], new_path]
    end
    @deluge.core.rename_files(tid, paths)
  end

end