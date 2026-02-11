# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'ostruct'

require_relative '../test_helper'

Storage.send(:remove_const, :Db) if Storage.const_defined?(:Db)
load File.expand_path('../../lib/storage/db.rb', __dir__)

class StorageDbTest < Minitest::Test
  def setup
    @tmp_dir = Dir.mktmpdir('storage-db-test')
    @db_path = File.join(@tmp_dir, 'test.db')
    @speaker = TestSupport::Fakes::Speaker.new
    @app_stub = OpenStruct.new(speaker: @speaker, env_flags: {})
  end

  def teardown
    FileUtils.remove_entry(@tmp_dir) if @tmp_dir && Dir.exist?(@tmp_dir)
  end

  def test_migrations_create_expected_schema
    with_stubbed_app do
      db = Storage::Db.new(@db_path)
      assert db.table_exists?(:torrents)
      schema = db.dump_schema
      assert_includes schema[:torrents].keys, :name
      assert_includes schema[:metadata_search].keys, :keywords
      db.database.disconnect
    end
  end

  def test_crud_operations_and_json_serialization
    with_stubbed_app do
      db = Storage::Db.new(@db_path)
      attributes = { tracker: 'tracker', f_type: 'movie' }
      db.insert_row('torrents', {
        name: 'example.torrent',
        identifier: 'foo',
        tattributes: attributes,
        status: 1
      })

      rows = db.get_rows('torrents', { name: 'example.torrent' })
      refute_empty rows
      row = rows.first
      assert_equal 'foo', row[:identifier]
      assert_equal attributes, row[:tattributes]
      refute_nil row[:created_at]
      refute_nil row[:updated_at]

      db.update_rows('torrents', { status: 4 }, { name: 'example.torrent' })
      updated = db.get_rows('torrents', { name: 'example.torrent' }).first
      assert_equal 4, updated[:status]

      db.delete_rows('torrents', { name: 'example.torrent' })
      assert_empty db.get_rows('torrents', { name: 'example.torrent' })
      db.database.disconnect
    end
  end

  def test_get_rows_supports_greater_than_filters
    with_stubbed_app do
      db = Storage::Db.new(@db_path)
      db.insert_row('torrents', { name: 'keep-me', status: 1 })
      db.insert_row('torrents', { name: 'skip-me', status: 0 })

      results = db.get_rows('torrents', {}, { 'status >' => 0 })

      assert_equal ['keep-me'], results.map { |row| row[:name] }
      db.database.disconnect
    end
  end

  def test_touch_rows_updates_timestamp
    with_stubbed_app do
      db = Storage::Db.new(@db_path)
      db.insert_row('torrents', { name: 'touch-me', status: 0 })
      initial = db.get_rows('torrents', { name: 'touch-me' }).first

      db.stub(:current_timestamp, '2024-01-01T00:00:00Z') do
        db.touch_rows('torrents', { name: 'touch-me' })
      end

      touched = db.get_rows('torrents', { name: 'touch-me' }).first
      assert_equal '2024-01-01T00:00:00Z', touched[:updated_at]
      assert_equal initial[:created_at], touched[:created_at]
      db.database.disconnect
    end
  end

  def test_get_rows_with_symbol_condition_value
    with_stubbed_app do
      db = Storage::Db.new(@db_path)
      torrent_name = 'Zootopia.2.2025.MULTi.VFQ.2160p.DV.WEB-DL.DDP5.1.H265-BOUC (Zootopie 2)'
      db.insert_row('torrents', { name: torrent_name, identifier: 'tt1234', status: 1 })

      rows = db.get_rows('torrents', { name: torrent_name.to_sym })
      refute_empty rows, 'Symbol condition values should be converted to strings'
      assert_equal torrent_name, rows.first[:name]
      db.database.disconnect
    end
  end

  def test_update_rows_with_symbol_condition_value
    with_stubbed_app do
      db = Storage::Db.new(@db_path)
      torrent_name = 'Test.Torrent.Name (Special Edition)'
      db.insert_row('torrents', { name: torrent_name, identifier: 'tt5678', status: 1 })

      db.update_rows('torrents', { status: 4 }, { name: torrent_name.to_sym })
      updated = db.get_rows('torrents', { name: torrent_name }).first
      assert_equal 4, updated[:status]
      db.database.disconnect
    end
  end

  def test_delete_rows_with_symbol_condition_value
    with_stubbed_app do
      db = Storage::Db.new(@db_path)
      torrent_name = 'Release.Name.With.Dots.And (Parens)'
      db.insert_row('torrents', { name: torrent_name, identifier: 'tt9999', status: 1 })

      db.delete_rows('torrents', { name: torrent_name.to_sym })
      assert_empty db.get_rows('torrents', { name: torrent_name })
      db.database.disconnect
    end
  end

  def test_schema_evolution_runs_new_migrations
    migration_dir = File.join(@tmp_dir, 'migrations')
    FileUtils.mkdir_p(migration_dir)
    FileUtils.cp(File.join(__dir__, '../../lib/db/migrations/001_initial_schema.rb'),
                 File.join(migration_dir, '001_initial_schema.rb'))

    with_stubbed_app do
      db = Storage::Db.new(@db_path, 0, migrations_path: migration_dir)
      db.database.disconnect
    end

    File.write(File.join(migration_dir, '002_add_test_flag.rb'), <<~RUBY)
      Sequel.migration do
        change do
          alter_table(:torrents) do
            add_column :test_flag, Integer
          end
        end
      end
    RUBY

    with_stubbed_app do
      db = Storage::Db.new(@db_path, 0, migrations_path: migration_dir)
      columns = db.database.schema(:torrents).map(&:first)
      assert_includes columns, :test_flag
      db.database.disconnect
    end
  end

  private

  def with_stubbed_app(&block)
    MediaLibrarian.stub(:app, @app_stub, &block)
  end
end
