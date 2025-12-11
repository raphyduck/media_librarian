# frozen_string_literal: true

module MediaLibrarian
  module Services
    class FileSystemScanRequest
      attr_reader :root_path, :type

      def initialize(root_path:, type: nil)
        @root_path = root_path
        @type = normalize(type)
      end

      private

      def normalize(type)
        type.to_s
      end
    end
  end
end
