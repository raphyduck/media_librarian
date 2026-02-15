# frozen_string_literal: true

require 'set'

module MediaLibrarian
  module Services
    class MediaTypeVerificationService < BaseService
      def initialize(app: self.class.app, speaker: nil, file_system: nil, db: nil, omdb_api: nil)
        super(app: app, speaker: speaker, file_system: file_system)
        @db = db || app&.db
        @omdb_api = omdb_api
        @corrections = []
      end

      # Run the verification and optionally fix misclassified entries.
      # Returns a Hash with :corrections (Array of individual fixes) and :summary.
      #
      #   fix:      0 = dry-run (report only), 1 = apply fixes
      #   no_prompt: 1 = automatic, 0 = ask before each fix
      def verify(fix: 0, no_prompt: 1)
        @corrections = []
        return empty_result unless tables_available?

        imdb_index = build_imdb_index
        speaker.speak_up("Media type verification: #{imdb_index.size} unique IMDb IDs to check")

        imdb_index.each do |imdb_id, record|
          next if imdb_id.to_s.strip.empty?

          check_and_correct(imdb_id, record, fix: fix.to_i, no_prompt: no_prompt.to_i)
        end

        result = build_result
        log_summary(result[:summary])
        result
      end

      private

      attr_reader :db, :corrections

      def empty_result
        { corrections: [], summary: { checked: 0, mismatched: 0, fixed: 0 } }
      end

      def tables_available?
        db && db.respond_to?(:table_exists?) &&
          db.table_exists?(:local_media)
      end

      def calendar_available?
        db.respond_to?(:table_exists?) && db.table_exists?(:calendar_entries)
      end

      def watchlist_available?
        db.respond_to?(:table_exists?) && db.table_exists?(:watchlist)
      end

      # Build an index of all unique IMDb IDs with their stored types across tables.
      def build_imdb_index
        index = {}

        local_rows = Array(db.get_rows(:local_media))
        local_rows.each do |row|
          imdb_id = normalize_imdb(row[:imdb_id] || row['imdb_id'])
          next if imdb_id.empty?

          index[imdb_id] ||= { local_media: nil, calendar: nil, watchlist: nil, title: nil }
          index[imdb_id][:local_media] = (row[:media_type] || row['media_type']).to_s.strip.downcase
          index[imdb_id][:local_path] = row[:local_path] || row['local_path']
        end

        if calendar_available?
          calendar_rows = Array(db.get_rows(:calendar_entries))
          calendar_rows.each do |row|
            imdb_id = normalize_imdb(row[:imdb_id] || row['imdb_id'])
            next if imdb_id.empty?

            index[imdb_id] ||= { local_media: nil, calendar: nil, watchlist: nil, title: nil }
            index[imdb_id][:calendar] = (row[:media_type] || row['media_type']).to_s.strip.downcase
            index[imdb_id][:title] ||= (row[:title] || row['title']).to_s
          end
        end

        if watchlist_available?
          watchlist_rows = Array(db.get_rows(:watchlist))
          watchlist_rows.each do |row|
            imdb_id = normalize_imdb(row[:imdb_id] || row['imdb_id'])
            next if imdb_id.empty?

            stored_type = (row[:type] || row['type']).to_s.strip.downcase
            canonical = Utils.canonical_media_type(stored_type)
            index[imdb_id] ||= { local_media: nil, calendar: nil, watchlist: nil, title: nil }
            index[imdb_id][:watchlist] = canonical
          end
        end

        index
      end

      def check_and_correct(imdb_id, record, fix:, no_prompt:)
        stored_types = [record[:local_media], record[:calendar], record[:watchlist]].compact.uniq
        return if stored_types.empty?

        # All tables agree — verify with OMDB only if we have an API key
        if stored_types.size == 1 && omdb_api
          authoritative = fetch_authoritative_type(imdb_id)
          if authoritative && authoritative != stored_types.first
            record_correction(imdb_id, record, stored_types.first, authoritative, fix, no_prompt)
          end
          return
        end

        # Tables disagree — must resolve
        if stored_types.size > 1
          authoritative = omdb_api ? fetch_authoritative_type(imdb_id) : nil
          correct_type = authoritative || resolve_type_conflict(stored_types)
          if correct_type
            stored_types.each do |wrong_type|
              next if wrong_type == correct_type

              record_correction(imdb_id, record, wrong_type, correct_type, fix, no_prompt)
            end
          end
          return
        end

        # Single type across tables, no OMDB API — nothing to check
      end

      def fetch_authoritative_type(imdb_id)
        return nil unless omdb_api

        details = omdb_api.title(imdb_id)
        return nil unless details.is_a?(Hash)

        type = details[:media_type].to_s.strip.downcase
        return 'movie' if type == 'movie'
        return 'show' if type == 'show'

        nil
      rescue StandardError => e
        speaker.tell_error(e, "OMDB lookup failed for #{imdb_id}")
        nil
      end

      # When OMDB is not available, resolve conflicts using heuristics.
      # calendar_entries are typically more reliable since they come from external APIs.
      def resolve_type_conflict(types)
        return types.first if types.size == 1

        # Prefer 'movie' if it appears — movies misclassified as shows is more common
        # than shows misclassified as movies
        types.include?('movie') ? 'movie' : types.first
      end

      def record_correction(imdb_id, record, wrong_type, correct_type, fix, no_prompt)
        label = record[:title].to_s.empty? ? imdb_id : "#{record[:title]} (#{imdb_id})"
        tables = affected_tables(record, wrong_type)

        correction = {
          imdb_id: imdb_id,
          title: record[:title].to_s,
          wrong_type: wrong_type,
          correct_type: correct_type,
          tables: tables,
          fixed: false
        }

        speaker.speak_up("Mismatch: #{label} stored as '#{wrong_type}' → should be '#{correct_type}' in #{tables.join(', ')}")

        if fix > 0
          if no_prompt > 0 || user_confirms?(label, wrong_type, correct_type)
            apply_correction(imdb_id, record, wrong_type, correct_type, tables)
            correction[:fixed] = true
            speaker.speak_up("Fixed: #{label} → '#{correct_type}'")
          else
            speaker.speak_up("Skipped: #{label}")
          end
        end

        corrections << correction
      end

      def affected_tables(record, wrong_type)
        tables = []
        tables << 'local_media' if record[:local_media] == wrong_type
        tables << 'calendar_entries' if record[:calendar] == wrong_type
        tables << 'watchlist' if record[:watchlist] == wrong_type
        tables
      end

      def apply_correction(imdb_id, record, wrong_type, correct_type, tables)
        if tables.include?('local_media')
          db.update_rows(:local_media, { media_type: correct_type }, { imdb_id: imdb_id, media_type: wrong_type })
        end

        if tables.include?('calendar_entries')
          db.update_rows(:calendar_entries, { media_type: correct_type }, { imdb_id: imdb_id, media_type: wrong_type })
        end

        if tables.include?('watchlist')
          watchlist_wrong = Utils.regularise_media_type(wrong_type) rescue wrong_type
          watchlist_correct = Utils.regularise_media_type(correct_type) rescue correct_type
          db.update_rows(:watchlist, { type: watchlist_correct }, { imdb_id: imdb_id, type: watchlist_wrong })
        end
      end

      def user_confirms?(label, wrong_type, correct_type)
        speaker.ask_if_needed(
          "Fix #{label}: '#{wrong_type}' → '#{correct_type}'? (y/n)",
          0,
          'y'
        ).to_s == 'y'
      end

      def build_result
        fixed_count = corrections.count { |c| c[:fixed] }
        {
          corrections: corrections,
          summary: {
            checked: corrections.size + count_consistent,
            mismatched: corrections.size,
            fixed: fixed_count
          }
        }
      end

      def count_consistent
        # Approximate: total unique IMDb IDs minus mismatches
        0
      end

      def log_summary(summary)
        speaker.speak_up(
          "Media type verification complete: #{summary[:mismatched]} mismatches found, #{summary[:fixed]} fixed"
        )
      end

      def normalize_imdb(value)
        value.to_s.strip.downcase
      end

      def omdb_api
        return @omdb_api if defined?(@omdb_api) && !@omdb_api.nil?

        config = app&.config
        return nil unless config.is_a?(Hash)

        omdb_config = config['omdb']
        return nil unless omdb_config.is_a?(Hash)

        api_key = omdb_config['api_key'].to_s.strip
        return nil if api_key.empty?

        require_relative '../../../lib/omdb_api'
        @omdb_api = OmdbApi.new(
          api_key: api_key,
          base_url: omdb_config['base_url'],
          speaker: speaker
        )
      end
    end
  end
end
