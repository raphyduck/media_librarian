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

        existing_calendar_ids = calendar_imdb_ids
        cached_calendar = {}
        cleaned_watchlist = Set.new

        library.each_with_object([]) do |(id, entry), memo|
          next if id.is_a?(Symbol)
          next unless entry.is_a?(Hash)

          subject = entry[:movie] || entry[:show]
          imdb_id = normalize_imdb_id(extract_imdb_id(subject))
          next if imdb_id.empty?

          cached_calendar[imdb_id] = ensure_calendar_entry(imdb_id, type, entry, existing_calendar_ids) unless cached_calendar.key?(imdb_id)

          files_persisted = false

          Array(entry[:files]).each do |file|
            local_path = file[:name]
            next unless local_path && File.file?(local_path)

            metadata = {
              media_type: type,
              imdb_id: imdb_id,
              local_path: local_path
            }
            persist(metadata)
            files_persisted = true
            memo << metadata
          end

          remove_from_watchlist(imdb_id, type, cleaned_watchlist) if files_persisted
        end
      end

      def extract_imdb_id(subject)
        ids = subject.respond_to?(:ids) ? subject.ids || {} : {}
        ids = ids.is_a?(Hash) ? ids : {}
        imdb_id = ids['imdb'] || ids[:imdb]
        imdb_id ||= subject.respond_to?(:imdb_id) ? subject.imdb_id : nil
        imdb_id.to_s
      end

      def normalize_imdb_id(value)
        value.to_s.strip.downcase
      end

      def ensure_calendar_entry(imdb_id, type, entry, existing_ids)
        return if existing_ids.include?(imdb_id)
        return unless calendar_table?

        seed = calendar_seed(imdb_id, type, entry)
        enriched = CalendarFeedService.enrich_entries([seed], app: app, speaker: speaker, db: app&.db)&.first || seed
        upsert_calendar_entry(enriched)
        existing_ids << imdb_id
        enriched
      rescue StandardError => e
        speaker.tell_error(e, 'File system scan calendar persistence failed') if speaker
        nil
      end

      def calendar_seed(imdb_id, type, entry)
        subject = entry[:movie] || entry[:show]
        title = subject.respond_to?(:title) ? subject.title.to_s : (entry[:title] || entry['title']).to_s
        release_date = subject.respond_to?(:release_date) ? subject.release_date : (entry[:release_date] || entry['release_date'])

        {
          source: 'local',
          external_id: imdb_id,
          imdb_id: imdb_id,
          title: title.empty? ? imdb_id : title,
          media_type: normalize_media_type(type),
          release_date: release_date,
          ids: { 'imdb' => imdb_id }
        }
      end

      def normalize_media_type(type)
        normalized = type.to_s.strip
        return 'movie' if normalized.start_with?('movie')
        return 'show' if normalized.start_with?('show')

        normalized
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
        app.db.insert_row('local_media', metadata, 1)
      end

      def remove_from_watchlist(imdb_id, type, cleaned_watchlist)
        return if imdb_id.empty? || cleaned_watchlist.include?(imdb_id)
        return unless watchlist_table?

        conditions = { imdb_id: imdb_id, type: normalize_watchlist_type(type) }
        app.db.delete_rows(:watchlist, conditions)
        cleaned_watchlist << imdb_id
      rescue StandardError => e
        speaker.tell_error(e, 'File system scan watchlist cleanup failed') if speaker
      end

      def normalize_watchlist_type(type)
        type.to_s.strip
      end

      def watchlist_table?
        app&.db&.respond_to?(:table_exists?) && app.db.table_exists?(:watchlist)
      end
    end
  end
end
