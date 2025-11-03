# frozen_string_literal: true

require 'tmpdir'

require_relative '../test_helper'
require_relative '../../lib/simple_speaker'
require_relative '../../lib/file_utils'
require_relative '../../app/library'

class LibraryTest < Minitest::Test
  def test_process_folder_marks_email_output
    speaker = SimpleSpeaker::Speaker.new
    env = build_stubbed_environment(speaker: speaker)
    old_application = MediaLibrarian.application
    MediaLibrarian.application = env.application
    Librarian.configure(app: env.application)
    Library.configure(app: env.application)
    Librarian.reset_notifications(Thread.current)

    Dir.mktmpdir do |dir|
      with_const(:CACHING_TTL, 60) do
        with_const(:DEFAULT_FILTER_PROCESSFOLDER, { 'movies' => {}, 'shows' => {} }) do
          with_const(:VALID_VIDEO_EXT, '.*') do
            with_const(:Vash, Class.new(Hash)) do
              bus_class = Class.new do
                def initialize(*)
                  @store = {}
                end

                def [](key)
                  @store[key]
                end

                def []=(key, *args)
                  @store[key] = args.last
                end
              end

              with_const(:BusVariable, bus_class) do
                FileUtils.stub(:search_folder, ->(*_) { [] }) do
                  Daemon.stub(:consolidate_children, ->(*) { {} }) do
                    Library.process_folder(type: 'movies', folder: dir)
                  end
                end
              end
            end
          end
        end
      end
    end

    assert_operator Thread.current[:send_email].to_i, :>, 0
    assert_includes Thread.current[:email_msg], 'Finished processing folder'
  ensure
    env&.cleanup
    MediaLibrarian.application = old_application
  end

  private

  def with_const(name, value)
    already_defined = Object.const_defined?(name)
    previous = Object.const_get(name) if already_defined
    Object.send(:remove_const, name) if already_defined
    Object.const_set(name, value)
    yield
  ensure
    Object.send(:remove_const, name)
    Object.const_set(name, previous) if already_defined
  end
end
