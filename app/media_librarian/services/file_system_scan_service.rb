# frozen_string_literal: true

require_relative '../../library'

module MediaLibrarian
  module Services
    class FileSystemScanService < BaseService
      def scan(request)
        root = File.expand_path(request.root_path.to_s)
        unless file_system.directory?(root)
          speaker.speak_up("Root path #{root} not found")
          return []
        end

        mapped_folders = request.folder_types
        mapped_folders[root] ||= 'movies'

        mapped_folders.flat_map do |folder, type|
          next [] unless file_system.directory?(folder)

          library = Library.process_folder(type: type, folder: folder, no_prompt: 1, cache_expiration: 1)
          persist_media_entries(library, type)
        end.flatten
      rescue StandardError => e
        speaker.tell_error(e, Utils.arguments_dump(binding))
        []
      end

      private

      def persist_media_entries(library, type)
        return [] unless library.is_a?(Hash)

        library.each_with_object([]) do |(id, entry), memo|
          next if id.is_a?(Symbol)
          next unless entry.is_a?(Hash)

          subject = entry[:movie] || entry[:show]
          external_id, source = extract_external_id(subject)
          next if external_id.to_s.empty?

          title = entry[:full_name] || entry[:name]
          year = subject.respond_to?(:year) ? subject.year : Metadata.identify_release_year(title)

          Array(entry[:files]).each do |file|
            local_path = file[:name]
            next unless local_path && File.file?(local_path)

            metadata = {
              media_type: type,
              title: title,
              year: year,
              external_id: external_id,
              external_source: source,
              local_path: local_path
            }
            persist(metadata)
            memo << metadata
          end
        end
      end

      def extract_external_id(subject)
        ids = subject.respond_to?(:ids) ? subject.ids || {} : {}
        prioritized = %w[imdb tmdb thetvdb tvdb trakt slug]
        key = prioritized.find { |k| ids[k] || ids[k.to_sym] }
        [ids[key] || ids[key&.to_sym], key]
      end

      def persist(metadata)
        app.db.insert_row('local_media', metadata, 1)
      end
    end
  end
end
