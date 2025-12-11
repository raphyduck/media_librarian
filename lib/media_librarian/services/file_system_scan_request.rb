# frozen_string_literal: true

module MediaLibrarian
  module Services
    class FileSystemScanRequest
      attr_reader :root_path, :folder_types

      def initialize(root_path:, folder_types: {})
        @root_path = root_path
        @folder_types = normalize(folder_types)
      end

      private

      def normalize(folder_types)
        (folder_types || {}).each_with_object({}) do |(path, type), memo|
          next if path.to_s.empty?

          memo[File.expand_path(path)] = type.to_s
        end
      end
    end
  end
end
