# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../lib/music_quality'
require_relative '../../app/music_search'
require_relative '../../app/soulseek_search'

class MusicSearchCsvTest < Minitest::Test
  # These import_csv tests exercise the tracker path only; neutralise the
  # Soulseek fallback so a machine that actually has sockseek installed does not
  # launch the real binary during the suite. Restored in teardown.
  def setup
    @__soulseek_available = SoulseekSearch.singleton_class.instance_method(:available?)
    SoulseekSearch.define_singleton_method(:available?) { false }
  end

  def teardown
    SoulseekSearch.singleton_class.send(:define_method, :available?, @__soulseek_available) if @__soulseek_available
  end

  def test_structured_csv_builds_artist_album_queries_per_row
    csv = +"Artiste,Album,Année,Titres\n" \
           "\"ABBA\",\"Super Trouper\",,7\n" \
           "\"Daft Punk\",\"Discovery\",2001,14\n"
    queries = MusicSearch.extract_queries(csv_content: csv)
    assert_equal ['ABBA Super Trouper', 'Daft Punk Discovery'], queries
  end

  def test_structured_csv_deduplicates_and_skips_blank_rows
    csv = +"Artist,Album\nABBA,Waterloo\nABBA,Waterloo\n,\n"
    assert_equal ['ABBA Waterloo'], MusicSearch.extract_queries(csv_content: csv)
  end

  def test_structured_csv_handles_accents_without_encoding_error
    csv = +"Artiste,Album,Année,Titres\n\"113\",\"Gravé dans la roche\",,1\n"
    # Simulate a non-UTF-8 default external encoding (as a mis-configured daemon
    # locale would produce when reading the temp CSV file).
    csv.force_encoding('ASCII-8BIT')
    queries = MusicSearch.extract_queries(csv_content: csv)
    assert_equal ['113 Gravé dans la roche'], queries
  end

  def test_falls_back_to_one_query_per_line_for_query_header
    csv = +"query\nDaft Punk Discovery\nABBA Waterloo\n"
    assert_equal ['Daft Punk Discovery', 'ABBA Waterloo'], MusicSearch.extract_queries(csv_content: csv)
  end

  def test_falls_back_to_one_query_per_line_for_headerless_list
    csv = +"Pink Floyd Dark Side\nMetallica Master of Puppets\n"
    assert_equal ['Pink Floyd Dark Side', 'Metallica Master of Puppets'],
                 MusicSearch.extract_queries(csv_content: csv)
  end

  def test_semicolon_separated_structured_csv
    csv = +"Artiste;Album;Année\nMano Negra;Casa Babylon;1994\n"
    assert_equal ['Mano Negra Casa Babylon'], MusicSearch.extract_queries(csv_content: csv)
  end

  def test_import_csv_report_builds_detailed_and_plain
    detailed = MusicSearch.import_csv_report(%w[a b], %w[c], true)
    assert_equal 2, detailed['total_queued']
    assert_equal %w[a b], detailed['queued_titles']
    assert_equal 1, detailed['not_found']
    assert_equal %w[c], detailed['not_found_entries']
    assert_equal 2, MusicSearch.import_csv_report(%w[a b], %w[c], false)
  end

  # A single failing query must not abort the whole import or wipe the report.
  def test_import_csv_survives_a_raising_query_and_still_reports
    speaker = Object.new
    def speaker.speak_up(*); end
    def speaker.tell_error(*); end
    fake_app = Object.new
    fake_app.define_singleton_method(:speaker) { speaker }
    fake_app.define_singleton_method(:respond_to?) { |*| true }

    sc = MusicSearch.singleton_class
    saved = {}
    %i[app search queue_download].each do |m|
      saved[m] = sc.instance_method(m) if sc.method_defined?(m) || sc.private_method_defined?(m)
    end

    begin
      MusicSearch.define_singleton_method(:app) { fake_app }
      # BOOM -> raises; NOPE -> no result (its artist also contains NOPE so the
      # artist fallback finds nothing either); otherwise a match.
      MusicSearch.define_singleton_method(:search) do |keyword:, **|
        raise 'boom tracker' if keyword.include?('BOOM')
        keyword.include?('NOPE') ? [] : [{ name: "#{keyword} [FLAC]", link: 'http://x/y.torrent', tracker: 't' }]
      end
      MusicSearch.define_singleton_method(:queue_download) { |**| { 'queued' => 'ok' } }

      csv = +"Artiste,Album\nABBA,Waterloo\nBOOM Crew,Album\nNOPE Band,Record\nQueen,Jazz\n"
      report = MusicSearch.import_csv(csv_content: csv, quality: 'flac', detailed: true)

      assert_equal 2, report['total_queued']
      assert_equal 2, report['not_found']
      assert_equal ['BOOM Crew Album', 'NOPE Band Record'], report['not_found_entries'].sort
    ensure
      saved.each { |m, um| sc.send(:define_method, m, um) }
    end
  end

  def test_extract_entries_keeps_artist_separate
    csv = +"Artiste,Album\nABBA,Super Trouper\nQuery Only,\n"
    entries = MusicSearch.extract_entries(csv_content: csv)
    assert_equal({ 'query' => 'ABBA Super Trouper', 'artist' => 'ABBA' }, entries[0])
    # headerless / free-text lines carry no separable artist
    plain = MusicSearch.extract_entries(csv_content: +"Pink Floyd Dark Side\n")
    assert_equal({ 'query' => 'Pink Floyd Dark Side', 'artist' => nil }, plain[0])
  end

  def test_non_artist_detection
    ['Various', 'Various Artists', 'VA', 'V.A.', 'Compilation', 'Soundtrack',
     'OST', 'Unknown Artist', 'Various Artists (Now 42)'].each do |name|
      assert MusicSearch.non_artist?(name), "expected #{name.inspect} to be a non-artist"
    end
    ['ABBA', 'Hans Zimmer', 'Daft Punk', 'The Cast'].each do |name|
      refute MusicSearch.non_artist?(name), "expected #{name.inspect} to be a real artist"
    end
  end

  def test_artist_fallback_selection
    assert_equal 'ABBA', MusicSearch.artist_fallback('ABBA', 'ABBA Super Trouper')
    assert_nil MusicSearch.artist_fallback('Various Artists', 'Various Artists Now 42')
    assert_nil MusicSearch.artist_fallback('ABBA', 'ABBA') # artist == full query already tried
    assert_nil MusicSearch.artist_fallback(nil, 'anything')
    assert_nil MusicSearch.artist_fallback('  ', 'anything')
  end

  def test_import_csv_retries_unfound_album_with_artist_once
    calls = []
    with_stubbed_music do |queue|
      MusicSearch.define_singleton_method(:search) do |keyword:, **|
        calls << keyword
        # album-specific queries miss; a bare-artist query for ABBA hits
        keyword == 'ABBA' ? [{ name: 'ABBA Discography [FLAC]', link: 'l', tracker: 't' }] : []
      end
      MusicSearch.define_singleton_method(:queue_download) { |**a| queue << a[:name] }

      csv = +"Artiste,Album\nABBA,Missing One\nABBA,Missing Two\nVarious Artists,Comp\n"
      report = MusicSearch.import_csv(csv_content: csv, detailed: true)

      # ABBA discography queued once via fallback; the second ABBA album does not
      # re-run the artist search; Various Artists is never fallback-searched.
      assert_equal 1, report['total_queued']
      assert_equal ['ABBA Discography [FLAC]'], queue
      assert_equal 1, calls.count('ABBA'), 'artist fallback must run once per artist'
      refute_includes calls, 'Various Artists'
      assert_equal 2, report['not_found']
    end
  end

  private

  # Runs the block with MusicSearch.app/search/queue_download replaced and then
  # restored. Yields a mutable array the queue_download stub can append to.
  def with_stubbed_music
    speaker = Object.new
    def speaker.speak_up(*); end
    def speaker.tell_error(*); end
    fake_app = Object.new
    fake_app.define_singleton_method(:speaker) { speaker }
    fake_app.define_singleton_method(:respond_to?) { |*| true }

    sc = MusicSearch.singleton_class
    saved = {}
    %i[app search queue_download].each do |m|
      saved[m] = sc.instance_method(m) if sc.method_defined?(m) || sc.private_method_defined?(m)
    end
    MusicSearch.define_singleton_method(:app) { fake_app }
    begin
      yield([])
    ensure
      saved.each { |m, um| sc.send(:define_method, m, um) }
    end
  end
end
