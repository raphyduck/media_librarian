# frozen_string_literal: true

module MediaLibrarian
  module Services
    class TorrentDownloadRequest
      attr_reader :torrent_name, :torrent_type, :path, :options,
                  :tracker, :nodl, :queue_file_handling

      def initialize(torrent_name:, torrent_type:, path:, options:, tracker: '',
                     nodl: 0, queue_file_handling: {})
        @torrent_name = torrent_name
        @torrent_type = torrent_type
        @path = path
        @options = options
        @tracker = tracker
        @nodl = nodl
        @queue_file_handling = queue_file_handling
      end
    end

    class TorrentQueueService < BaseService
      def initialize(app: self.class.app, speaker: nil, file_system: nil, client:)
        super(app: app, speaker: speaker, file_system: file_system)
        @client = client
      end

      def parse_pending_downloads
        speaker.speak_up('Downloading torrent(s) added during the session (if any)', 0)
        app.db.get_rows('torrents', { status: 2 }).each do |torrent_row|
          torrent = Cache.object_unpack(torrent_row[:tattributes])
          log_torrent_details(torrent, torrent_row) if Env.debug?
          tdid = (Time.now.to_f * 1000).to_i.to_s
          url = torrent[:torrent_link] ? torrent[:torrent_link] : ''
          magnet = torrent[:magnet_link]
          options = build_download_options(torrent_row, torrent, tdid)
          Cache.queue_state_add_or_update('deluge_options', options)
          torrent_type = 1
          success = false
          tries = 5
          nodl = TorrentSearch.get_tracker_config(torrent[:tracker], app: app)['no_download'].to_i
          speaker.speak_up("Will download torrent '#{torrent_row[:name]}' on #{torrent[:tracker]}#{' (url = ' + url.to_s + ')' if url.to_s != ''}")
          if url.to_s != '' && nodl.zero?
            path = TorrentSearch.get_torrent_file(tdid, url)
          elsif magnet.to_s != '' && nodl.zero?
            path = magnet
            torrent_type = 2
          else
            speaker.speak_up 'no_download setting is activated for this tracker, please download manually.'
            path = 'nodl'
          end
          path = app.temp_dir + "/#{torrent_row[:name]}.torrent" if path.to_s == '' && File.exist?(app.temp_dir + "/#{torrent_row[:name]}.torrent")
          next if path.nil?
          while (tries -= 1) >= 0 && !success
            request = TorrentDownloadRequest.new(
              torrent_name: torrent_row[:name],
              torrent_type: torrent_type,
              path: path,
              options: options[torrent_row[:name]],
              tracker: torrent[:tracker],
              nodl: nodl,
              queue_file_handling: torrent[:files].is_a?(Array) && !torrent[:files].empty? ? { torrent_row[:identifier] => torrent[:files] } : {}
            )
            success = process_download_request(request)
            speaker.speak_up "Download of torrent '#{torrent_row[:name]}' #{success ? 'succeeded' : 'failed'}" if (Env.debug? || !success) && nodl.zero?
            FileUtils.rm(app.temp_dir + "/#{tdid}.torrent") rescue nil
          end
          client.delete_torrent(torrent_row[:name], 0, 1) unless success
        end
      end

      def process_added_torrents
        while Cache.queue_state_get('deluge_torrents_added').length != 0
          tid = Cache.queue_state_shift('deluge_torrents_added')
          tries = 10
          begin
            status = app.t_client.get_torrent_status(tid, ['name', 'files', 'total_size', 'progress'])
            opts = Cache.queue_state_select('deluge_options') { |_, v| v && v[:info_hash] == tid }
            opts = Cache.queue_state_select('deluge_options') { |torrent_name, _| torrent_name == status['name'] } if opts.nil? || opts.empty?
            opts = Cache.queue_state_select('deluge_options') { |torrent_name, _| app.str_closeness.getDistance(torrent_name[0..30], status['name'][0..30]) > 0.9 } if opts.nil? || opts.empty?
            speaker.speak_up("Processing added torrent #{status['name']} (tid '#{tid})'") unless (opts || {}).empty?
            (opts || {}).each do |torrent_name, option|
              torrent_cache = app.db.get_rows('torrents', { name: torrent_name }).first
              app.db.update_rows('torrents', { torrent_id: tid, status: 3 }, { name: torrent_name }) if torrent_cache && torrent_cache[:torrent_id].nil?
              set_options = {}
              main_file = client.find_main_file(status, option[:whitelisted_extensions] || [])
              if main_file.empty? && option[:expect_main_file].to_i > 0
                speaker.speak_up "Torrent '#{torrent_cache[:name]}' (tid #{tid}) does not contain an archive or an acceptable file, removing" if Env.debug?
                client.delete_torrent(torrent_name, tid)
                next
              end
              torrent_qualities = Quality.qualities_merge(torrent_name, option[:assume_quality], '', option[:category]).split('.')
              set_options = client.main_file_only(status, main_file) if option[:main_only] && !main_file.empty?
              client.rename_torrent_files(tid, status['files'], option[:rename_main].to_s, torrent_qualities, option[:category])
              unless set_options.empty?
                speaker.speak_up("Will set options: #{set_options}")
                app.t_client.set_torrent_options([tid], set_options)
              end
              app.t_client.queue_bottom([tid]) unless option[:queue].to_s == 'top'
              if option[:add_paused].to_i > 0
                app.t_client.pause_torrent([tid])
              else
                app.t_client.resume_torrent([tid])
              end
              Cache.queue_state_remove('deluge_options', torrent_name)
            end
          rescue StandardError => e
            if !(tries -= 1).zero?
              sleep 30
              retry
            else
              speaker.tell_error(e, Utils.arguments_dump(binding))
            end
          end
        end
      end

      def process_completed_torrents
        speaker.speak_up('Will process completed torrents', 0) if Env.debug?
        Cache.queue_state_get('deluge_torrents_completed').each do |tid, data|
          torrent_record = app.db.get_rows('torrents', {}, { 'torrent_id like ' => tid }).first
          remove_it = 0
          begin
            if torrent_record.nil?
              app.t_client.remove_torrent(tid, true) if app.remove_torrent_on_completion
            else
              torrent = Cache.object_unpack(torrent_record[:tattributes])
              speaker.speak_up("Processing torrent '#{torrent_record[:name]}' (tid '#{tid}')...", 0) if Env.debug?
              target_seed_time = (TorrentSearch.get_tracker_config(torrent[:tracker], app: app)['seed_time'] || TorrentClient.get_config('deluge', 'default_seed_time') || 1).to_i
              seed_time = app.t_client.get_torrent_status(tid, ['active_time'])['active_time'].to_i - data[:active_time].to_i
              if seed_time.nil?
                speaker.speak_up 'Torrent no longer exists, will remove now...' if Env.debug?
                remove_it = 1
              elsif target_seed_time <= seed_time.to_i / 3600
                speaker.speak_up "Torrent has been seeding for #{seed_time.to_i / 3600} hours, more than the seed time set at #{target_seed_time} hour(s) for this tracker. Will remove now..." if Env.debug?
                app.t_client.remove_torrent(tid, false) if app.remove_torrent_on_completion && torrent_record[:status].to_i < 5
                app.db.update_rows('torrents', { status: [torrent_record[:status], 4].max }, { name: torrent_record[:name] })
                remove_it = 1
              elsif Env.debug?
                speaker.speak_up("Torrent has been seeding for #{seed_time.to_i / 3600} hours, less than the seed time set at #{target_seed_time} hour(s) for this tracker. Skipping...", 0)
              end
            end
          rescue StandardError => e
            if e.to_s == 'InvalidTorrentError'
              speaker.speak_up 'Torrent no longer exists, removing from database...' if Env.debug?
              remove_it = 1
            else
              speaker.tell_error(e, Utils.arguments_dump(binding))
            end
          end
          if remove_it > 0
            Cache.queue_state_remove('deluge_torrents_completed', tid)
            file_system.rm_r(data[:path]) if data[:path].to_s != '' && file_system.exist?(data[:path].to_s)
          end
        end
      end

      def process_download_request(request)
        if request.torrent_type == 1 && request.nodl.zero?
          file = File.open(request.path, 'r')
          torrent = file.read
          file.close
          meta = BEncode.load(torrent, { ignore_trailing_junk: 1 })
          meta_id = Digest::SHA1.hexdigest(meta['info'].bencode)
          Cache.queue_state_add_or_update('deluge_options', { request.torrent_name => request.options.merge({ info_hash: meta_id }) })
          download = { type: 1, type_str: 'file', file: torrent, filename: File.basename(request.path) }
        elsif request.nodl.zero?
          meta_id = request.options[:tdid]
          download = { type: 2, type_str: 'magnet', url: request.path }
        else
          meta_id = Time.now.to_f
        end
        if request.nodl.zero?
          if !app.db.get_rows('torrents', { torrent_id: meta_id }).empty? && meta_id.to_s != ''
            speaker.speak_up "Torrent with TID '#{meta_id}' already exists, nothing to do" if Env.debug?
            client.delete_torrent(request.torrent_name, 0, 1)
            return true
          end
          speaker.speak_up "Adding #{download[:type_str]} torrent #{request.torrent_name}"
          client.download_file(download, request.options.deep_dup, meta_id)
          Cache.queue_state_add_or_update('deluge_torrents_added', meta_id) if meta_id.to_s != '' && request.torrent_type == 1
        end
        app.db.update_rows('torrents', { status: 3, torrent_id: meta_id }, { name: request.torrent_name })
        Cache.queue_state_add_or_update('file_handling', request.queue_file_handling, 1, 1) unless request.queue_file_handling.empty?
        true
      rescue StandardError => e
        Cache.queue_state_remove('deluge_options', request.torrent_name)
        speaker.tell_error(
          e,
          "torrentclient.process_download_torrent('#{request.torrent_type}', '#{request.path}', '#{request.options}', '#{request.tracker}')"
        )
        false
      end

      private

      attr_reader :client

      def log_torrent_details(torrent, torrent_row)
        speaker.speak_up "#{LINE_SEPARATOR}\nTorrent attributes:"
        (torrent + torrent_row.select { |key, _| [:name, :identifiers].include?(key) }).each { |key, value| speaker.speak_up "#{key} = #{value}" }
      end

      def build_download_options(torrent_row, torrent, tdid)
        {
          torrent_row[:name] => {
            tdid: tdid,
            move_completed: Utils.parse_filename_template(torrent[:move_completed].to_s, torrent),
            rename_main: Utils.parse_filename_template(torrent[:rename_main].to_s, torrent),
            queue: torrent[:queue].to_s,
            assume_quality: torrent[:assume_quality],
            entry_id: torrent_row[:identifiers].join,
            added_at: Time.now.to_i,
            category: torrent[:category]
          }.merge(torrent.select { |key, _| [:add_paused, :expect_main_file, :main_only, :whitelisted_extensions].include?(key) })
        }
      end

    end
  end
end
