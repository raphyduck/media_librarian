# frozen_string_literal: true

require 'minitest/autorun'

require_relative 'support/dependency_stubs'
require_relative '../librarian'
require_relative 'support/container_helpers'

module TestSupport
  module LibrarianState
    def reset_librarian_state!
      singleton = Librarian.singleton_class
      singleton.instance_variable_set(:@app, nil)
      singleton.instance_variable_set(:@command_registry, nil)
      Librarian.debug_classes = []
    end
  end
end

Minitest::Test.include(TestSupport::ContainerHelpers)
Minitest::Test.include(TestSupport::LibrarianState)
