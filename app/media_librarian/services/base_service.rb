# frozen_string_literal: true

module MediaLibrarian
  module Services
    class BaseService
      include MediaLibrarian::AppContainerSupport

      def initialize(app: self.class.app, speaker: nil, file_system: nil)
        @app = app
        @speaker = speaker || SpeakerAdapter.new(app&.speaker)
        @file_system = file_system || FileSystemAdapter.new
      end

      private

      attr_reader :app, :speaker, :file_system
    end

    class SpeakerAdapter
      def initialize(delegate)
        @delegate = delegate
      end

      def speak_up(message, *args)
        mutable_message = if message.is_a?(String) && message.frozen?
                            message.dup
                          else
                            message
                          end
        delegate&.speak_up(mutable_message, *args)
      end

      def ask_if_needed(question, no_prompt = 0, default = nil)
        delegate&.ask_if_needed(question, no_prompt, default)
      end

      def tell_error(error, context = nil, *_args)
        delegate&.tell_error(error, context)
      end

      private

      attr_reader :delegate
    end

    class FileSystemAdapter
      def initialize(delegate = FileUtils)
        @delegate = delegate
      end

      def exist?(path)
        File.exist?(path)
      end

      def directory?(path)
        File.directory?(path)
      end

      def search_folder(path, criteria)
        delegate.search_folder(path, criteria)
      end

      def get_extension(path)
        delegate.get_extension(path)
      end

      def mkdir(path)
        delegate.mkdir(path)
      end

      def mkdir_p(path)
        delegate.mkdir_p(path)
      end

      def mv(source, destination)
        delegate.mv(source, destination)
      end

      def rm_r(path)
        delegate.rm_r(path)
      end

      def md5sum(path)
        delegate.md5sum(path)
      end

      def ln_r(source, destination)
        delegate.ln_r(source, destination)
      end

      def chdir(path, &block)
        Dir.chdir(path, &block)
      end

      private

      attr_reader :delegate
    end
  end
end
