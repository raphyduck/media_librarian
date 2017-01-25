class TorrentClient

  def initialize()
    @deluge = Deluge::Rpc::Client.new(
        host: $config['deluge']['host'], port: 58846,
        login: $config['deluge']['username'], password: $config['deluge']['password']
    )
    @added_torrent_files = []
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
    if move_completed
      options['move_completed_path'] = move_completed
      options['move_completed'] = true
    end
    @deluge.core.add_torrent_file(filename, Base64.encode64(file), options)
  end

  def listen
    @deluge.register_event('TorrentAddedEvent') do |torrent_id|
      Speaker.speak_up "Torrent #{torrent_id} was successfully added!"
      @added_torrent_files.each do |path|
        File.delete(path)
      end
      @added_torrent_files = []
    end
  end

  def process_download_torrents
    Speaker.speak_up("Processing torrent(s) to download")
    Find.find($temp_dir).each do |path|
      unless FileTest.directory?(path)
        if path.end_with?('torrent')
          @added_torrent_files << path
          file = File.open(path, "r")
          torrent = file.read
          file.close
          download_file(torrent, File.basename(path))
        end
      end
    end
  end

end