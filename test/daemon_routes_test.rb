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
end
