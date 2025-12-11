# frozen_string_literal: true

class FileSystemScan
  include MediaLibrarian::AppContainerSupport

  def self.scan(root_path:, type: 'movies')
    request = MediaLibrarian::Services::FileSystemScanRequest.new(
      root_path: root_path,
      type: type
    )
    MediaLibrarian::Services::FileSystemScanService.new(app: app).scan(request)
  end
end
