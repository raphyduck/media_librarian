# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../app/daemon'

class DaemonRoutesTest < Minitest::Test
  EXPECTED_AUTHENTICATED_PATHS = %w[
    /jobs /commands /template_commands /status /stop /restart /update-stop
    /calendar /calendar/import /calendar/search /calendar/refresh /collection
    /torrents/pending /torrents/validate /torrents/delete /logs
    /config /config/reload /api-config /api-config/reload
    /templates /scheduler /scheduler/reload /trackers /trackers/info
    /watchlist /watchlist/import-csv
    /music/search /music/download /music/import-csv /music/organize /ws
  ].freeze

  def routes
    Daemon.send(:authenticated_routes)
  end

  def test_covers_exactly_the_expected_authenticated_paths
    assert_equal EXPECTED_AUTHENTICATED_PATHS.sort, routes.keys.sort
  end

  def test_every_route_maps_to_a_callable_handler
    routes.each do |path, handler|
      assert_respond_to handler, :call, "handler for #{path} must be callable"
      assert_equal 2, handler.arity.abs, "handler for #{path} should accept (req, res)"
    end
  end

  def test_login_and_static_routes_are_not_in_the_authenticated_table
    # '/session' (login) and '/' (static assets) are intentionally unauthenticated
    # and registered separately, so they must never appear in this table.
    refute_includes routes.keys, '/session'
    refute_includes routes.keys, '/'
  end

  FakeRequest = Struct.new(:request_method, :query)

  def test_normalize_query_encoding_retags_binary_query_values_as_utf8
    binary_form = WEBrick::HTTPUtils::FormData.new('Âme idéale'.dup.force_encoding(Encoding::ASCII_8BIT))
    binary_plain = 'été'.dup.force_encoding(Encoding::ASCII_8BIT)
    req = FakeRequest.new('GET', { 'title' => binary_form, 'plain' => binary_plain })

    Daemon.send(:normalize_query_encoding, req)

    assert_equal Encoding::UTF_8, req.query['title'].encoding
    assert_equal 'Âme idéale', req.query['title'].to_s
    assert req.query['title'].valid_encoding?
    assert_equal Encoding::UTF_8, req.query['plain'].encoding
    assert_equal 'été', req.query['plain']
  end

  def test_normalize_query_encoding_scrubs_invalid_bytes
    invalid = "bad\xFFbytes".dup.force_encoding(Encoding::ASCII_8BIT)
    req = FakeRequest.new('GET', { 'q' => invalid })

    Daemon.send(:normalize_query_encoding, req)

    assert_equal Encoding::UTF_8, req.query['q'].encoding
    assert req.query['q'].valid_encoding?
  end

  def test_normalize_query_encoding_leaves_non_get_requests_alone
    # On POST/PUT WEBrick may build the query by consuming the request body
    # (form/multipart), which would break parse_payload; those verbs are skipped.
    binary = 'été'.dup.force_encoding(Encoding::ASCII_8BIT)
    req = FakeRequest.new('POST', { 'q' => binary })

    Daemon.send(:normalize_query_encoding, req)

    assert_equal Encoding::ASCII_8BIT, req.query['q'].encoding
  end
end
