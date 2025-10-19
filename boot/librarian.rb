# frozen_string_literal: true

require_relative '../lib/media_librarian/application'

module MediaLibrarian
  module Boot
    module_function

    def application
      @application ||= MediaLibrarian.application
    end

    def container
      @container ||= application.container
    end
  end
end
