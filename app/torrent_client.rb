class TorrentClient

  def initialize()
    @deluge = Deluge::Rpc::Client.new(
        host: $config['deluge']['host'], port: 58846,
        login: $config['deluge']['username'], password: $config['deluge']['password']
    )
    @deluge_connected = nil
    @tdid = 0
  rescue => e
    $speaker.tell_error(e, "TorrentClient.new")
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
    options = {}
    if move_completed.to_s != ''
      options['move_completed_path'] = move_completed
      options['move_completed'] = true
    end
    if magnet.to_i > 0
      $t_client.add_torrent_magnet(url, options)
    else
      $t_client.add_torrent_url(url, options)
    end
  end

  def download_file(file, filename, move_completed = nil)
    options = {}
    if move_completed.to_s != ''
      options['move_completed_path'] = move_completed
      options['move_completed'] = true
    end
    $t_client.add_torrent_file(filename, Base64.encode64(file), options)
  end

  def find_main_file(status)
    status['files'].each do |file|
      if file['size'].to_i > (status['total_size'].to_i * 0.9)
        return file
      end
    end
    nil
  rescue => e
    $speaker.tell_error(e, "torrentclient.find_main_file")
  end

  def listen
    @deluge.register_event('TorrentAddedEvent') do |torrent_id|
      $speaker.speak_up "Torrent #{torrent_id} was successfully added!"
      Utils.queue_state_add_or_update('deluge_torrents_added', {torrent_id => 2})
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
    return if Env.pretend?
    while Utils.queue_state_get('deluge_torrents_added').length != 0
      tid = Utils.queue_state_shift('deluge_torrents_added')
      tid = tid[0]
      processed_torrent_id ||= 0
      next if (processed_torrent_id += 1) > 60
      begin
        status = $t_client.get_torrent_status(tid, ['name', 'files', 'total_size', 'progress'])
        $speaker.speak_up("Processing added torrent #{status['name']}")
        opts = Utils.queue_state_select('deluge_options') { |_, v| v[:info_hash] == tid }
        opts = Utils.queue_state_select('deluge_options') { |_, v| v[:t_name] == status['name'] } if opts.nil?
        if opts.nil? || opts.empty?
          opts = Utils.queue_state_select('deluge_options') { |_, v| $str_closeness.getDistance(v[:t_name][0..30], status['name'][0..30]) > 0.9 }
        end
        (opts || []).each do |did, o|
          Utils.entry_update('download', o[:entry_id], tid)
          set_options = {}
          File.delete($temp_dir + "/#{did}.torrent") rescue nil
          if (o[:rename_main] && o[:rename_main] != '') || (o[:main_only] && o[:main_only].to_i > 0)
            main_file = find_main_file(status)
            if main_file
              set_options = main_file_only(status, main_file) if o[:main_only]
              rename_main_file(tid, status['files'], o[:rename_main]) if o[:rename_main] && o[:rename_main] != ''
            end
          end
          unless set_options.empty?
            $t_client.set_torrent_options([tid], set_options)
            $speaker.speak_up("Will set options: #{set_options}")
          end
          Utils.queue_state_remove('deluge_options', did)
          $t_client.queue_bottom([tid]) #Queue to bottom once all processed
        end
      rescue => e
        $speaker.tell_error(e, "TorrentClient.process_added_torrents")
        Utils.queue_state_add_or_update('deluge_torrents_added', {tid => 2})
        sleep 10
      end
    end
  end

  def process_download_torrents
    return if Env.pretend?
    $speaker.speak_up("#{LINE_SEPARATOR}\nDownloading torrent(s) added during the session (if any)", 0)
    Find.find($temp_dir).each do |path|
      unless FileTest.directory?(path)
        if path.end_with?('torrent')
          file = File.open(path, "r")
          torrent = file.read
          file.close
          @tdid = File.basename(path).gsub('.torrent', '').to_i
          opts = Utils.queue_state_get('deluge_options')[@tdid]
          unless opts.nil?
            begin
              meta = BEncode.load(torrent, {:ignore_trailing_junk => 1})
              meta_id = Digest::SHA1.hexdigest(meta['info'].bencode)
              Utils.queue_state_add_or_update('deluge_options', {@tdid => opts.merge({:info_hash => meta_id})})
              Utils.entry_update('download', opts[:entry_id], meta_id)
            rescue => e
              TraktList.list_cache_remove(@tdid)
              Utils.queue_state_select('dir_to_delete', 1) { |_, v| v != @tdid }
              File.delete($temp_dir + "/#{@tdid}.torrent") rescue nil
              $speaker.tell_error(e, "TorrentClient.process_download_torrents - get info_hash")
            end
            $speaker.speak_up "Adding torrent #{opts[:t_name]}"
            download_file(torrent, File.basename(path), opts[:move_completed])
            Utils.queue_state_add_or_update('deluge_torrents_added', {meta_id => 1})
          end
        end
      end
    end
    Utils.queue_state_get('pending_magnet_links').each do |did, m|
      opts = Utils.queue_state_get('deluge_options')[did]
      $speaker.speak_up "Adding torrent #{opts[:t_name]}"
      download(m, opts[:move_completed], 1) unless opts.nil?
    end
  end

  def rename_main_file(tid, files, new_dir_name)
    $speaker.speak_up("Will move all files in torrent in a directory '#{new_dir_name}'.")
    paths = []
    files.each do |file|
      old_name = File.basename(file['path'])
      new_path = new_dir_name + '/' + old_name
      paths << [file['index'], new_path]
    end
    $t_client.rename_files(tid, paths)
  end

  def method_missing(name, *args)
    tries ||= 3
    authenticate
    if args.empty?
      eval("@deluge.core").method(name).call
    else
      eval("@deluge.core").method(name).call(*args)
    end
  rescue => e
    @deluge_connected = nil
    if !(tries -= 1).zero?
      retry
    else
      $speaker.tell_error(e, "TorrentClient.#{name}")
      TraktList.list_cache_remove(@tdid)
      Utils.queue_state_select('dir_to_delete', 1) { |_, v| v != @tdid }
      raise 'Lost connection'
    end
  end

end