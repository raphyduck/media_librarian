# frozen_string_literal: true

module MediaLibrarian
  # Mixin that equips a class with application container awareness. Classes
  # include this module to receive a configurable `app` accessor that exposes
  # the application services. The container must be provided explicitly via the
  # `configure` class method which keeps dependencies injectable for tests.
  module AppContainerSupport
    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      attr_writer :app

      def configure(app:)
        self.app = app
      end

      def app
        @app || raise(ArgumentError, "#{name} requires an application container")
      end
    end

    private

    def app
      self.class.app
    end
  end
end
