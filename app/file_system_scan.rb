# frozen_string_literal: true

class FileSystemScan
  include MediaLibrarian::AppContainerSupport

  def self.scan(root_path:, folder_types: {})
    request = MediaLibrarian::Services::FileSystemScanRequest.new(
      root_path: root_path,
      folder_types: folder_types
    )
    MediaLibrarian::Services::FileSystemScanService.new(app: app).scan(request)
  end
end
