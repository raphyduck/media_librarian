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
    @deluge.close rescue nil
    @deluge.connect
    @deluge_connected = 1
    listen
  end

  def disconnect
    @deluge.close
    @deluge_connected = nil
  end

  def download(url, move_completed = nil, magnet = 0)
    authenticate unless @deluge_connected
    options = {}
    if move_completed
      options['move_completed_path'] = move_completed
      options['move_completed'] = true
    end
    if magnet.to_i > 0
      @deluge.core.add_torrent_magnet(url, options) rescue @deluge_connected = nil
    else
      @deluge.core.add_torrent_url(url, options) rescue @deluge_connected = nil
    end
    raise 'Lost connection' if @deluge_connected.nil?
  end

  def download_file(file, filename, move_completed = nil)
    self.authenticate unless @deluge_connected
    options = {}
    if move_completed && move_completed != ''
      options['move_completed_path'] = move_completed
      options['move_completed'] = true
    end
    @deluge.core.add_torrent_file(filename, Base64.encode64(file), options) rescue @deluge_connected = nil
    raise 'Lost connection' if @deluge_connected.nil?
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
    self.authenticate unless @deluge_connected rescue nil
    while $deluge_torrents_added.length != 0
      tid = $deluge_torrents_added.shift
      begin
        status = @deluge.core.get_torrent_status(tid, ['name', 'files', 'total_size','progress']) rescue @deluge_connected = nil
        opts = $deluge_options.select{|_,v| v['info_hash'] == tid}
        opts = $deluge_options.select{|_,v| v['t_name'] == status['name']} if opts.nil?
        if opts.nil? || opts.empty?
          opts = $deluge_options.select{|_,v| $str_closeness.getDistance(v['t_name'][0..30], status['name'][0..30]) > 0.9}
        end
        if opts && !opts.empty?
          did = opts.first[0]
          opts = opts.first[1]
          set_options = {}
          magnet = $pending_magnet_links[did]
          unless magnet
            File.delete($temp_dir + "/#{did}.torrent") rescue nil
            if (opts['rename_main'] && opts['rename_main'] != '') || (opts['main_only'] && opts['main_only'].to_i > 0)
              main_file = find_main_file(status)
              if main_file
                set_options = main_file_only(status, main_file) if opts['main_only']
                rename_main_file(tid, status['files'], opts['rename_main']) if opts['rename_main'] && opts['rename_main'] != ''
              end
            end
            unless set_options.empty?
              @deluge.core.set_torrent_options([tid], set_options)
              Speaker.speak_up("Will set options: #{set_options}")
            end
          end
          $deluge_options.delete(did)
        end
      rescue => e
        Speaker.tell_error(e, "TorrentClient.process_added_torrents")
      end
    end
  end

  def process_download_torrents
    Speaker.speak_up("#{LINE_SEPARATOR}
Downloading torrent(s) added during the session (if any)")
    Find.find($temp_dir).each do |path|
      unless FileTest.directory?(path)
        if path.end_with?('torrent')
          file = File.open(path, "r")
          torrent = file.read
          file.close
          did = File.basename(path).gsub('.torrent', '').to_i
          opts = $deluge_options[did]
          unless opts.nil?
            begin
              meta = BEncode.load(torrent, {:ignore_trailing_junk=>1})
              meta_id = Digest::SHA1.hexdigest(meta['info'].bencode)
              $deluge_options[did]['info_hash'] = meta_id
              download_file(torrent, File.basename(path), opts['move_completed'])
              $deluge_torrents_preadded << meta_id
            rescue => e
              $cleanup_trakt_list.select!{|x| x[:id] != did}
              $dir_to_delete.select!{|x| x[:id] != did}
              File.delete($temp_dir + "/#{did}.torrent") rescue nil
              Speaker.tell_error(e, "TorrentClient.process_download_torrents - get info_hash")
            end
          end
        end
      end
    end
    $pending_magnet_links.each do |did, m|
      opts = $deluge_options[did]
      begin
        download(m, opts['move_completed'], 1) unless opts.nil?
      rescue => e
        $cleanup_trakt_list.select!{|x| x[:id] != did}
        $dir_to_delete.select!{|x| x[:id] != did}
        Speaker.tell_error(e, "TorrentClient.process_download_torrents - process magnet links")
      end
    end
  end

  def rename_main_file(tid, files, new_dir_name)
    Speaker.speak_up("Will move all files in torrent in a directory '#{new_dir_name}'.")
    paths = []
    files.each do |file|
      old_name = File.basename(file['path'])
      new_path = new_dir_name + '/' + old_name
      paths << [file['index'], new_path]
    end
    @deluge.core.rename_files(tid, paths)
  end

end