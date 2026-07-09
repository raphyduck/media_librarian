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
  # --- write_tags (full internal tag writing) ---------------------------------

  def test_flac_content_commands_map_keys_to_vorbis_fields
    TagWriter.stub(:which, '/usr/bin/metaflac') do
      tags = { artist: 'Daft Punk', title: 'Aerodynamic', album: 'Discovery',
               track: '03', disc: '1', year: '2001' }
      cmds = TagWriter.content_commands('/lib/x.flac', tags, %i[artist title album track disc year])
      assert_equal 1, cmds.size, 'metaflac writes all fields in one invocation'
      cmd = cmds.first
      assert_includes cmd, '--set-tag=ARTIST=Daft Punk'
      assert_includes cmd, '--set-tag=TITLE=Aerodynamic'
      assert_includes cmd, '--set-tag=ALBUM=Discovery'
      assert_includes cmd, '--set-tag=TRACKNUMBER=3'
      assert_includes cmd, '--set-tag=DISCNUMBER=1'
      assert_includes cmd, '--set-tag=DATE=2001'
      assert_equal '/lib/x.flac', cmd.last
    end
  end

  def test_mp3_content_commands_one_frame_each
    TagWriter.stub(:which, '/usr/bin/mid3v2') do
      tags = { artist: 'Air', title: 'La Femme d\'Argent', album: 'Moon Safari', track: '1' }
      cmds = TagWriter.content_commands('/lib/x.mp3', tags, %i[artist title album track])
      assert_equal 4, cmds.size
      assert(cmds.any? { |c| c.include?('--TPE1') && c.include?('Air') })
      assert(cmds.any? { |c| c.include?('--TIT2') })
      assert(cmds.any? { |c| c.include?('--TALB') && c.include?('Moon Safari') })
      assert(cmds.any? { |c| c.include?('--TRCK') && c.include?('1') })
      assert(cmds.all? { |c| c.last == '/lib/x.mp3' })
    end
  end

  def test_write_tags_only_missing_skips_present_fields
    TagWriter.stub(:which, '/usr/bin/metaflac') do
      tags = { artist: 'X', title: 'Y', album: 'Z', track: '1' }
      current = { artist: 'X', title: '', album: 'Z', track: '' } # title+track missing
      written = TagWriter.write_tags('/lib/x.flac', tags, only_missing: true,
                                     current: current, dry_run: true)
      assert_equal %i[title track], written, 'writes only the fields blank in the file'
    end
  end

  def test_write_tags_overwrite_mode_writes_all_present_lookup_fields
    TagWriter.stub(:which, '/usr/bin/metaflac') do
      tags = { artist: 'X', title: 'Y', album: 'Z', track: '1' }
      current = { artist: 'OLD', title: 'OLD', album: 'Z', track: '1' }
      written = TagWriter.write_tags('/lib/x.flac', tags, only_missing: false,
                                     current: current, dry_run: true)
      assert_equal %i[artist title album track], written
    end
  end

  def test_write_tags_noop_for_unsupported_format
    TagWriter.stub(:which, nil) do
      written = TagWriter.write_tags('/lib/x.m4a', { artist: 'X' }, dry_run: true)
      assert_equal [], written, 'unsupported format is a graceful no-op'
    end
  end

  def test_write_tags_dry_run_never_executes
    ran = false
    TagWriter.stub(:which, '/usr/bin/metaflac') do
      TagWriter.stub(:run, ->(*) { ran = true; true }) do
        TagWriter.write_tags('/lib/x.flac', { artist: 'X', title: 'Y', album: 'Z', track: '1' },
                             current: {}, dry_run: true)
      end
    end
    refute ran, 'dry-run must not shell out to the tagger'
  end

  def test_write_tags_includes_albumartist_when_missing
    TagWriter.stub(:which, '/usr/bin/metaflac') do
      tags    = { artist: 'Radiohead', albumartist: 'Radiohead', album: 'OK Computer', title: 'Airbag', track: '1' }
      current = { artist: 'Radiohead', albumartist: '', album: 'OK Computer', title: 'Airbag', track: '1' }
      written = TagWriter.write_tags('/lib/x.flac', tags, only_missing: true, current: current, dry_run: true)
      assert_includes written, :albumartist, 'fills a blank ALBUMARTIST (Navidrome grouping key)'
    end
  end

  def test_flac_content_commands_map_albumartist_to_vorbis_field
    TagWriter.stub(:which, '/usr/bin/metaflac') do
      cmds = TagWriter.content_commands('/lib/x.flac', { albumartist: 'Various Artists' }, %i[albumartist])
      assert_includes cmds.first, '--set-tag=ALBUMARTIST=Various Artists'
    end
  end

end
