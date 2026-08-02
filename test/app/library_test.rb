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

  def test_children_speaks_from_children
    speaker = TestSupport::Fakes::Speaker.new
    env = build_stubbed_environment(speaker: speaker)
    old_application = MediaLibrarian.application
    MediaLibrarian.application = env.application
    Librarian.configure(app: env.application)
    Library.configure(app: env.application)

    calls = []
    Librarian.stub(:route_cmd, lambda { |args, *_|
      calls << args
      Library.child_speak(args[2])
    }) do
      Library.test_children(nb: 2)
    end

    assert_equal 2, calls.length
    assert_equal ["Je suis l'enfant 1", "Je suis l'enfant 2"], speaker.messages
  ensure
    env&.cleanup
    MediaLibrarian.application = old_application
  end

  def test_handle_completed_download_forwards_set_original_audio_default
    speaker = TestSupport::Fakes::Speaker.new
    env = build_stubbed_environment(speaker: speaker)
    old_application = MediaLibrarian.application
    MediaLibrarian.application = env.application
    Librarian.configure(app: env.application)
    Library.configure(app: env.application)

    Dir.mktmpdir do |dir|
      completed = File.join(dir, 'completed')
      film_dir = File.join(completed, 'movies', 'Wonderland.2024.MULTi.1080p')
      FileUtils.mkdir_p(film_dir)
      mkv = File.join(film_dir, 'Wonderland.2024.MULTi.1080p.mkv')
      File.write(mkv, 'payload')
      destination_root = File.join(dir, 'library')
      FileUtils.mkdir_p(destination_root)

      captured = []
      rename_stub = lambda do |*args|
        captured << args
        File.join(destination_root, 'Wonderland (2024).mkv')
      end
      search_stub = lambda do |folder, _opts|
        folder == File.join(completed, 'movies') ? [[film_dir]] : [[mkv]]
      end

      with_const(:FOLDER_HIERARCHY, { 'movies' => 0, 'shows' => 1 }) do
        with_const(:EXTENSIONS_TYPE, { audio: [], video: ['mkv'] }) do
          handled = nil
          Library.stub(:rename_media_file, rename_stub) do
            FileUtils.stub(:search_folder, search_stub) do
              Quality.stub(:qualities_merge, ->(*_) { '' }) do
                handled, _list, error = Library.handle_completed_download(
                  torrent_path: completed,
                  torrent_name: 'movies',
                  completed_folder: completed,
                  destination_folder: destination_root,
                  handling: { 'file_types' => ['mkv'], 'movies' => { 'move_to' => destination_root } },
                  root_process: 0,
                  set_original_audio_default: 2
                )
                assert_equal 0, error
              end
            end
          end
          assert_equal 1, handled
        end
      end

      assert_equal 1, captured.length
      assert_equal 2, captured.first.last, 'set_original_audio_default must be forwarded through recursive calls'
    end
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
