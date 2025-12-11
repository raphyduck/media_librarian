# frozen_string_literal: true

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

          scan_folder(folder, type)
        end
      rescue StandardError => e
        speaker.tell_error(e, Utils.arguments_dump(binding))
        []
      end

      private

      def scan_folder(folder, type)
        Library.process_folder(type: type, folder: folder, no_prompt: 1, folder_hierarchy: folder_hierarchy)
                .each_value
                .with_object([]) do |media, memo|
          metadata = build_metadata(media)
          next unless metadata

          persist(metadata)
          memo << metadata
        end
      end

      def extract_external_id(subject)
        ids = subject.respond_to?(:ids) ? subject.ids || {} : {}
        prioritized = %w[imdb tmdb thetvdb tvdb trakt slug]
        key = prioritized.find { |k| ids[k] || ids[k.to_sym] }
        [ids[key] || ids[key&.to_sym], key]
      end

      def build_metadata(media)
        subject = media[:movie] || media[:show]
        return unless subject

        external_id, source = extract_external_id(subject)
        return if external_id.to_s.empty?

        title = media[:full_name] || media[:name]
        path = Array(media[:files]).find { |f| f.is_a?(Hash) && f[:name] }&.[](:name)
        return unless title && path

        {
          media_type: media[:type],
          title: title,
          year: subject.respond_to?(:year) ? subject.year : Metadata.identify_release_year(title),
          external_id: external_id,
          external_source: source,
          local_path: path
        }
      end

      def persist(metadata)
        app.db.insert_row('local_media', metadata, 1)
      end

      def folder_hierarchy
        defined?(FOLDER_HIERARCHY) ? FOLDER_HIERARCHY : {}
      end
    end
  end
end
