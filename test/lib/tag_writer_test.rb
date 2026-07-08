# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../lib/tag_writer'

class TagWriterTest < Minitest::Test
  def test_flac_compilation_commands_shape
    TagWriter.stub(:which, '/usr/bin/metaflac') do
      cmds = TagWriter.compilation_commands('/lib/x.flac', 'Various Artists')
      assert_equal 1, cmds.size
      cmd = cmds.first
      assert_equal '/usr/bin/metaflac', cmd.first
      assert_includes cmd, '--set-tag=ALBUMARTIST=Various Artists'
      assert_includes cmd, '--set-tag=COMPILATION=1'
      assert_equal '/lib/x.flac', cmd.last
    end
  end

  def test_mp3_compilation_commands_use_tpe2_and_tcmp
    TagWriter.stub(:which, '/usr/bin/mid3v2') do
      cmds = TagWriter.compilation_commands('/lib/x.mp3', 'Various Artists')
      assert_equal 2, cmds.size
      assert(cmds.any? { |c| c.include?('--TPE2') && c.include?('Various Artists') }, 'sets album artist (TPE2)')
      assert(cmds.any? { |c| c.include?('--TCMP') }, 'sets iTunes compilation flag (TCMP)')
      assert(cmds.all? { |c| c.last == '/lib/x.mp3' })
    end
  end

  def test_no_commands_for_missing_binary_or_unsupported_format
    TagWriter.stub(:which, nil) do
      assert_empty TagWriter.compilation_commands('/lib/x.flac')
    end
    TagWriter.stub(:which, '/usr/bin/metaflac') do
      assert_empty TagWriter.compilation_commands('/lib/x.wav')
    end
  end

  def test_stamp_is_dry_run_by_default_and_never_executes
    ran = false
    TagWriter.stub(:which, '/usr/bin/metaflac') do
      TagWriter.stub(:run, ->(*) { ran = true; true }) do
        assert TagWriter.stamp_compilation('/lib/x.flac', dry_run: true)
        refute ran, 'dry-run must not execute the tagger'
      end
    end
  end

  def test_stamp_returns_false_when_unsupported
    TagWriter.stub(:which, nil) do
      refute TagWriter.stamp_compilation('/lib/x.flac', dry_run: false)
    end
  end
end
