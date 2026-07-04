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
end
