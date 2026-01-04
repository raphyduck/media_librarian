# frozen_string_literal: true

require 'set'

require_relative '../../library'
require_relative 'calendar_feed_service'

module MediaLibrarian
  module Services
    class FileSystemScanService < BaseService
      def scan(request)
        root = File.expand_path(request.root_path.to_s)
        unless file_system.directory?(root)
          speaker.speak_up("Root path #{root} not found")
          return []
        end

        folder_type = request.type.empty? ? 'movies' : request.type
        library = Library.process_folder(type: folder_type, folder: root, no_prompt: 1, cache_expiration: 1)
        persist_media_entries(library, folder_type)
      rescue StandardError => e
        speaker.tell_error(e, Utils.arguments_dump(binding))
        []
      end

      private

      def persist_media_entries(library, type)
        return [] unless library.is_a?(Hash)

        normalized_type = Utils.canonical_media_type(type)

        existing_calendar_ids = calendar_imdb_ids
        cached_calendar = {}
        cleaned_watchlist = Set.new

        library.each_with_object([]) do |(id, entry), memo|
          next if id.is_a?(Symbol)
          next unless entry.is_a?(Hash)

          subject = entry[:movie] || entry[:show]
          imdb_id = normalize_imdb_id(extract_imdb_id(subject))
          watchlist_id = imdb_id
          watchlist_id = normalize_imdb_id(extract_watchlist_id(entry, subject)) if watchlist_id.empty?

          cached_calendar[imdb_id] = ensure_calendar_entry(imdb_id, normalized_type, entry, existing_calendar_ids) unless imdb_id.empty? || cached_calendar.key?(imdb_id)

          files_found = false

          Array(entry[:files]).each do |file|
            local_path = file[:name]
            next unless local_path && File.file?(local_path)

            files_found = true
            next if imdb_id.empty?

            metadata = {
              media_type: normalized_type,
              imdb_id: imdb_id,
              local_path: local_path,
              created_at: file_created_at(local_path)
            }
            persist(metadata)
            memo << metadata
          end

          remove_from_watchlist(watchlist_id, normalized_type, cleaned_watchlist) if files_found
        end
      end

      def extract_imdb_id(subject)
        ids = subject.respond_to?(:ids) ? subject.ids || {} : {}
        ids = ids.is_a?(Hash) ? ids : {}
        imdb_id = ids['imdb'] || ids[:imdb]
        imdb_id ||= subject.respond_to?(:imdb_id) ? subject.imdb_id : nil
        imdb_id.to_s
      end

      def extract_watchlist_id(entry, subject)
        metadata = entry[:metadata] || entry['metadata']
        metadata = metadata.is_a?(Hash) ? metadata : {}
        ids = metadata[:ids] || metadata['ids'] || {}
        ids = ids.is_a?(Hash) ? ids : {}

        [
          entry[:external_id],
          entry['external_id'],
          metadata[:imdb_id],
          metadata['imdb_id'],
          metadata[:external_id],
          metadata['external_id'],
          ids[:imdb],
          ids['imdb'],
          subject.respond_to?(:imdb_id) ? subject.imdb_id : nil,
          subject.respond_to?(:external_id) ? subject.external_id : nil,
          (subject.respond_to?(:ids) && subject.ids.is_a?(Hash)) ? subject.ids[:imdb] : nil,
          (subject.respond_to?(:ids) && subject.ids.is_a?(Hash)) ? subject.ids['imdb'] : nil
        ].compact.map(&:to_s).map(&:strip).find { |value| !value.empty? }.to_s
      end

      def normalize_imdb_id(value)
        value.to_s.strip.downcase
      end

      def ensure_calendar_entry(imdb_id, media_type, entry, existing_ids)
        return if existing_ids.include?(imdb_id)
        return unless calendar_table?

        seed = calendar_seed(imdb_id, media_type, entry)
        enriched = CalendarFeedService.enrich_entries([seed], app: app, speaker: speaker, db: app&.db)&.first || seed
        upsert_calendar_entry(enriched)
        existing_ids << imdb_id
        enriched
      rescue StandardError => e
        speaker.tell_error(e, 'File system scan calendar persistence failed') if speaker
        nil
      end

      def calendar_seed(imdb_id, media_type, entry)
        subject = entry[:movie] || entry[:show]
        title = subject.respond_to?(:title) ? subject.title.to_s : (entry[:title] || entry['title']).to_s
        release_date = subject.respond_to?(:release_date) ? subject.release_date : (entry[:release_date] || entry['release_date'])

        {
          source: 'local',
          external_id: imdb_id,
          imdb_id: imdb_id,
          title: title.empty? ? imdb_id : title,
          media_type: media_type,
          release_date: release_date,
          ids: { 'imdb' => imdb_id }
        }
      end

      def upsert_calendar_entry(entry)
        return unless entry && app&.db

        app.db.insert_row(:calendar_entries, entry, 1)
      end

      def calendar_table?
        app&.db&.respond_to?(:table_exists?) && app.db.table_exists?(:calendar_entries)
      end

      def calendar_imdb_ids
        return Set.new unless calendar_table?

        rows = app.db.get_rows(:calendar_entries)
        rows.each_with_object(Set.new) do |row, memo|
          imdb_id = (row[:imdb_id] || row['imdb_id']).to_s.strip.downcase
          memo << imdb_id unless imdb_id.empty?
        end
      rescue StandardError
        Set.new
      end

      def persist(metadata)
        existing = existing_local_media(metadata)
        if existing && same_local_media?(existing, metadata)
          log_scan("Scan skip: #{metadata[:imdb_id]} #{metadata[:local_path]} created_at=#{existing[:created_at]}")
          return
        end

        if existing
          log_scan("Scan update: #{metadata[:imdb_id]} #{metadata[:local_path]} created_at=#{existing[:created_at]} -> #{metadata[:created_at]}")
        else
          log_scan("Scan insert: #{metadata[:imdb_id]} #{metadata[:local_path]} created_at=#{metadata[:created_at]}")
        end
        app.db.insert_row('local_media', metadata, 1)
      end

      def file_created_at(path)
        stat = File.stat(path)
        return stat.birthtime if stat.respond_to?(:birthtime) && stat.birthtime

        stat.mtime
      end

      def existing_local_media(metadata)
        return unless app&.db
        return if metadata[:media_type].to_s.empty? || metadata[:imdb_id].to_s.empty?

        app.db.get_rows(:local_media, { media_type: metadata[:media_type], imdb_id: metadata[:imdb_id] }).first
      end

      def same_local_media?(existing, metadata)
        existing[:local_path].to_s == metadata[:local_path].to_s &&
          normalize_timestamp(existing[:created_at]) == normalize_timestamp(metadata[:created_at])
      end

      def normalize_timestamp(value)
        return '' if value.nil?
        return value.iso8601 if value.respond_to?(:iso8601)

        value.to_s
      end

      def log_scan(message)
        speaker&.speak_up(message, 0) if Env.debug?
      end

      def remove_from_watchlist(imdb_id, type, cleaned_watchlist)
        normalized_type = normalize_watchlist_type(type)
        if imdb_id.empty? || normalized_type.empty?
          speaker&.speak_up("File system scan watchlist skip: imdb_id='#{imdb_id}', type='#{type}'", 0) if Env.debug?
          return
        end
        return if cleaned_watchlist.include?(imdb_id)
        return unless watchlist_table?

        conditions = { imdb_id: imdb_id, type: normalized_type }
        app.db.delete_rows(:watchlist, conditions)
        cleaned_watchlist << imdb_id
      rescue StandardError => e
        speaker.tell_error(e, 'File system scan watchlist cleanup failed') if speaker
      end

      def normalize_watchlist_type(type)
        normalized = type.to_s.strip.downcase
        return 'movies' if normalized.start_with?('movie')
        return 'shows' if normalized.start_with?('show') || normalized.start_with?('tv') || normalized.start_with?('series')

        normalized
      end

      def watchlist_table?
        app&.db&.respond_to?(:table_exists?) && app.db.table_exists?(:watchlist)
      end
    end
  end
end
