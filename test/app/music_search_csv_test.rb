# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../app/music_search'

class MusicSearchCsvTest < Minitest::Test
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
      MusicSearch.define_singleton_method(:search) do |keyword:, **|
        raise 'boom tracker' if keyword.include?('BOOM')
        keyword.include?('NOPE') ? [] : [{ name: "#{keyword} [FLAC]", link: 'http://x/y.torrent', tracker: 't' }]
      end
      MusicSearch.define_singleton_method(:queue_download) { |**| { 'queued' => 'ok' } }

      csv = +"Artiste,Album\nABBA,Waterloo\nDaft Punk,BOOM\nSomeone,NOPE\nQueen,Jazz\n"
      report = MusicSearch.import_csv(csv_content: csv, quality: 'flac', detailed: true)

      assert_equal 2, report['total_queued']
      assert_equal 2, report['not_found']
      assert_equal ['Daft Punk BOOM', 'Someone NOPE'], report['not_found_entries'].sort
    ensure
      saved.each { |m, um| sc.send(:define_method, m, um) }
    end
  end
end
