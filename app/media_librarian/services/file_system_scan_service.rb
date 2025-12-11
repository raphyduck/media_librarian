# frozen_string_literal: true

require 'find'

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

        results = []
        Find.find(root) do |path|
          next if File.directory?(path)
          next unless video_file?(path)

          type = media_type_for(path, mapped_folders)
          next unless type

          metadata = extract_metadata(path, type, root)
          next unless metadata

          persist(metadata)
          results << metadata
        end

        results
      rescue StandardError => e
        speaker.tell_error(e, Utils.arguments_dump(binding))
        []
      end

      private

      def media_type_for(path, mapped_folders)
        expanded_path = File.expand_path(path)
        folder = mapped_folders.keys.sort_by(&:length).reverse.find do |mapped_folder|
          expanded_path.start_with?(mapped_folder)
        end
        mapped_folders[folder] if folder
      end

      def extract_metadata(path, type, base_folder)
        item_name, item = Metadata.identify_title(path, type, 1, folder_hierarchy[type], base_folder)
        return unless item && item_name

        full_name, _ids, info = Metadata.parse_media_filename(path, type, item, item_name, 1, folder_hierarchy, base_folder)
        subject = info[:movie] || info[:show] || item
        external_id, source = extract_external_id(subject)
        return if external_id.to_s.empty?

        {
          media_type: type,
          title: full_name,
          year: subject.respond_to?(:year) ? subject.year : Metadata.identify_release_year(full_name),
          external_id: external_id,
          external_source: source,
          local_path: path
        }
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

      def folder_hierarchy
        defined?(FOLDER_HIERARCHY) ? FOLDER_HIERARCHY : {}
      end

      def video_file?(path)
        extension = File.extname(path).delete('.').downcase
        EXTENSIONS_TYPE[:video].include?(extension)
      end
    end
  end
end
