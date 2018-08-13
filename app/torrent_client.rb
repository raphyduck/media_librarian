class TorrentClient

  def initialize
    @deluge = Deluge::Rpc::Client.new(
        host: $config['deluge']['host'], port: 58846,
        login: $config['deluge']['username'], password: $config['deluge']['password']
    )
    @deluge_connected = nil
    @tname = ''
  rescue => e
    $speaker.tell_error(e, Utils.arguments_dump(binding))
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

  def download_file(download, options = {}, meta_id = '')
    options.select! {|key, _| [:move_completed, :rename_main, :main_only].include?(key)}
    options = Utils.recursive_typify_keys(options, 0) if options.is_a?(Hash)
    if options['move_completed'].to_s != ''
      options['move_completed_path'] = options['move_completed']
      options['move_completed'] = true
    end
    options['add_paused'] = true unless download[:type] > 1
    case download[:type]
    when 1
      $t_client.add_torrent_file(download[:filename], Base64.encode64(download[:file]), options)
      if meta_id.to_s != ''
        status = $t_client.get_torrent_status(meta_id, ['name', 'progress'])
        raise 'Download failed' if status.nil? || status.empty?
      end
    when 2
      $t_client.add_torrent_magnet(download[:url], options)
    when 3
      $t_client.add_torrent_url(download[:url], options)
    end
  rescue => e
    if meta_id.to_s != '' && download.is_a?(Hash) && download[:type].to_i == 1
      status = $t_client.get_torrent_status(meta_id, ['name', 'progress'])
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
        $speaker.speak_up "The file '#{file['path']}' is not on the allowed extension list (#{whitelisted_exts.join(', ')}), will not be included" if Env.debug?
        fname = 'illegalext'
      end
      files[fname] = {:s => 0, :f => []} unless files[fname]
      files[fname][:s] += file['size'].to_i
      files[fname][:f] << file['path']
    end
    files.select {|k, f| k != 'illegalext' && f[:s] > 0.9 * status['total_size'].to_i}.map {|_, v| v[:f]}.flatten
  rescue => e
    $speaker.tell_error(e, Utils.arguments_dump(binding))
    []
  end

  def listen
    @deluge.register_event('TorrentAddedEvent') do |torrent_id|
      $speaker.speak_up "Torrent #{torrent_id} was successfully added!"
      Cache.queue_state_add_or_update('deluge_torrents_added', torrent_id) if torrent_id.to_s != ''
    end
  end

  def main_file_only(status, main_files)
    priorities = []
    main_files = [main_files] unless main_files.is_a?(Array)
    status['files'].map {|f| f['path']}.each do |f|
      priorities << (main_files.include?(f) ? 1 : 0)
    end
    {'file_priorities' => priorities}
  end

  def parse_torrents_to_download
    $speaker.speak_up('Downloading torrent(s) added during the session (if any)', 0)
    $db.get_rows('torrents', {:status => 2}).each do |t|
      torrent = Cache.object_unpack(t[:tattributes])
      if Env.debug?
        $speaker.speak_up "#{LINE_SEPARATOR}\nTorrent attributes:"
        torrent.each {|k, v| $speaker.speak_up "#{k} = #{v}"}
      end
      tdid = (Time.now.to_f * 1000).to_i.to_s
      @tname = torrent[:name]
      url = torrent[:torrent_link] ? torrent[:torrent_link] : ''
      magnet = torrent[:magnet_link]
      path, ttype = nil, 1
      success = false
      tries = 5
      while (tries -= 1) >= 0 && !success
        $speaker.speak_up("Will download torrent '#{torrent[:name]}' on #{torrent[:tracker]}#{' (url = ' + url.to_s + ')' if url.to_s != ''}")
        File.delete($temp_dir + "/#{tdid}.torrent") rescue nil
        if url.to_s != ''
          path = TorrentSearch.get_torrent_file(torrent[:tracker], tdid, url)
        elsif magnet.to_s != ''
          path, ttype = magnet, 2
        end
        opts = {
            @tname => {
                :tdid => tdid,
                :move_completed => Utils.parse_filename_template(torrent[:move_completed].to_s, torrent),
                :rename_main => Utils.parse_filename_template(torrent[:rename_main].to_s, torrent),
                :entry_id => torrent[:identifiers].join,
                :added_at => Time.now.to_i
            }
        }
        opts[@tname].merge!(torrent.select {|k, _| [:add_paused, :expect_main_file, :main_only, :whitelisted_extensions].include?(k)})
        Cache.queue_state_add_or_update('deluge_options', opts)
        success = process_download_torrent(ttype, path, opts[@tname], torrent[:tracker]) if path.to_s != ''
        $speaker.speak_up "Download of torrent '#{@tname}' #{success ? 'succeeded' : 'failed'}" if Env.debug? || !success
        if success
          if torrent[:files].is_a?(Array) && !torrent[:files].empty?
            torrent[:files].each do |f|
              Cache.queue_state_add_or_update('dir_to_delete', {f[:name] => @tname}) if f[:type] == 'file'
              TraktAgent.list_cache_add(f[:trakt_list], f[:trakt_type], f[:trakt_obj], @tname) if f[:type] == 'trakt'
              #TODO: Move that bit upon torrent completion success
            end
          end
        else
          TorrentSearch.reauth(torrent[:tracker])
        end
      end
      unless success
        delete_torrent(t[:name], 0, 1)
        if torrent[:tracker].to_s != ''
          TorrentSearch.launch_search(torrent[:tracker], '').init rescue nil
        end
      end
    end
    @tname = ''
  end

  def process_added_torrents
    while Cache.queue_state_get('deluge_torrents_added').length != 0
      tid = Cache.queue_state_shift('deluge_torrents_added')
      tries = 10
      begin
        status = $t_client.get_torrent_status(tid, ['name', 'files', 'total_size', 'progress'])
        $speaker.speak_up("Processing added torrent #{status['name']}")
        opts = Cache.queue_state_select('deluge_options') {|_, v| v[:info_hash] == tid}
        opts = Cache.queue_state_select('deluge_options') {|tn, _| tn == status['name']} if opts.nil? || opts.empty?
        if opts.nil? || opts.empty?
          opts = Cache.queue_state_select('deluge_options') {|tn, _| $str_closeness.getDistance(tn[0..30], status['name'][0..30]) > 0.9}
        end
        (opts || {}).each do |tname, o|
          torrent_cache = $db.get_rows('torrents', {:name => tname}).first
          if torrent_cache && torrent_cache[:torrent_id].nil?
            $db.update_rows('torrents', {:torrent_id => tid}, {:name => tname})
          end
          set_options = {}
          if (o[:rename_main] && o[:rename_main] != '') || o[:main_only].to_i > 0
            main_file = find_main_file(status, o[:whitelisted_extensions] | [])
            if !main_file.empty?
              set_options = main_file_only(status, main_file) if o[:main_only]
              rename_main_file(tid, status['files'], o[:rename_main]) if o[:rename_main] && o[:rename_main] != ''
            elsif o[:expect_main_file].to_i > 0
              $speaker.speak_up "Torrent '#{torrent_cache[:name]}' (tid #{tid}) is does not contain an archive or an acceptable file, removing" if Env.debug?
              delete_torrent(tname, tid)
              next
            end
          end
          unless set_options.empty?
            $t_client.set_torrent_options([tid], set_options)
            $speaker.speak_up("Will set options: #{set_options}")
          end
          $t_client.queue_bottom([tid]) #Queue to bottom once all processed
          if o[:add_paused].to_i > 0
            $t_client.pause_torrent([tid])
          else
            $t_client.resume_torrent([tid])
          end
          Cache.queue_state_remove('deluge_options', tname)
        end
      rescue => e
        if !(tries -= 1).zero?
          sleep 30
          retry
        else
          $speaker.tell_error(e, Utils.arguments_dump(binding))
        end
      end
    end
  end

  def process_download_torrent(torrent_type, path, opts, tracker = '')
    if torrent_type == 1
      file = File.open(path, "r")
      torrent = file.read
      file.close
      meta = BEncode.load(torrent, {:ignore_trailing_junk => 1})
      meta_id = Digest::SHA1.hexdigest(meta['info'].bencode)
      Cache.queue_state_add_or_update('deluge_options', {@tname => opts.merge({:info_hash => meta_id})})
      download = {:type => 1, :type_str => 'file', :file => torrent, :filename => File.basename(path)}
      Cache.queue_state_add_or_update('deluge_torrents_added', meta_id) if meta_id.to_s != ''
    else
      meta_id = opts[:tdid]
      download = {:type => 2, :type_str => 'magnet', :url => path}
    end
    $speaker.speak_up "Adding #{download[:type_str]} torrent #{@tname}"
    download_file(download, opts.deep_dup, meta_id)
    $db.update_rows('torrents', {:status => 3, :torrent_id => meta_id}, {:name => @tname})
    true
  rescue => e
    $speaker.tell_error(
        e,
        "torrentclient.process_download_torrent('#{torrent_type}', '#{path}', '#{opts}', '#{tracker}')"
    )
    false
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

  def delete_torrent(tname, tid = 0, remove_opts = 0)
    $t_client.remove_torrent(tid, true) if tid.to_i > 0 rescue nil
    $db.update_rows('torrents', {:status => -1}, {:name => tname})
    Cache.queue_state_remove('deluge_options', tname) if remove_opts.to_i > 0
  end

  def method_missing(name, *args)
    tries ||= 3
    debug_str = "#{name}#{'(' + args.map {|a| a.to_s[0..100]}.join(',') + ')' if args}"
    authenticate
    $speaker.speak_up "Running @deluge.core.#{debug_str}" if Env.debug?
    return if Env.pretend? && !['get_torrent_status'].include?(name)
    if args.empty?
      eval("@deluge.core").method(name).call
    else
      eval("@deluge.core").method(name).call(*args)
    end
  rescue => e
    @deluge_connected = nil
    if !(tries -= 1).zero?
      sleep 3
      retry
    else
      $speaker.tell_error(e, "$t_client.#{debug_str}")
      if @tname.to_s != ''
        TraktAgent.list_cache_remove(@tname)
        Cache.queue_state_select('dir_to_delete', 1) {|_, v| v != @tname}
      end
      raise 'Lost connection'
    end
  end

end