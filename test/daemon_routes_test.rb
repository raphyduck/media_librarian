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

  def with_fake_calendar_repository(fake)
    sc = Daemon.singleton_class
    saved = sc.instance_method(:calendar_repository)
    Daemon.define_singleton_method(:calendar_repository) { fake }
    yield
  ensure
    sc.send(:define_method, :calendar_repository, saved)
  end

  def test_calendar_search_lists_local_matches_and_deduplicates_provider_results
    local_entry = { imdb_id: 'tt1', title: "L'Âme idéale", type: 'movie', year: 2025, in_interest_list: true }
    fake_repo = Object.new
    fake_repo.define_singleton_method(:entries) { |_filters| { entries: [local_entry] } }
    fake_repo.define_singleton_method(:load_entries) { [local_entry] }
    provider_entries = [
      { imdb_id: 'tt1', title: "L'Ame ideale", source: 'tmdb' },
      { imdb_id: 'tt2', title: 'Autre film', source: 'tmdb' }
    ]

    with_fake_calendar_repository(fake_repo) do
      merged = Daemon.send(:merge_calendar_search_results, provider_entries, "l'âme idéale", nil, nil)

      assert_equal %w[tt1 tt2], merged.map { |entry| entry[:imdb_id] }
      assert merged.first[:in_calendar], 'a locally-tracked entry is flagged in_calendar'
      assert merged.first[:in_interest_list], 'local flags survive the merge'
      refute merged.last[:in_calendar], 'an unknown provider result stays importable'
    end
  end

  def test_calendar_search_folds_known_provider_results_into_their_local_entry
    # Calendar entries are stored under their original title (resolved at
    # persist time, backfilled by scripts/fix_calendar_entry_original_titles.rb),
    # so a fold keeps the local entry — title and flags — untouched.
    known = { imdb_id: 'tt3', title: "L'Âme idéale", type: 'movie', downloaded: true }
    fake_repo = Object.new
    fake_repo.define_singleton_method(:entries) { |_filters| { entries: [] } }
    fake_repo.define_singleton_method(:load_entries) { [known] }
    provider_entries = [{ imdb_id: 'tt3', title: 'You Found Me', source: 'tmdb' }]

    with_fake_calendar_repository(fake_repo) do
      merged = Daemon.send(:merge_calendar_search_results, provider_entries, "l'âme idéale", nil, nil)

      assert_equal ["L'Âme idéale"], merged.map { |entry| entry[:title] }, 'the local (original) title is displayed'
      assert merged.first[:in_calendar]
      assert merged.first[:downloaded], 'local flags survive the fold'
    end
  end

  def test_calendar_search_fold_keeps_local_title_for_non_tmdb_providers
    # OMDb titles are IMDb primary titles (often English), not original ones:
    # they must never override the local title.
    known = { imdb_id: 'tt4', title: 'Titre local', type: 'movie' }
    fake_repo = Object.new
    fake_repo.define_singleton_method(:entries) { |_filters| { entries: [] } }
    fake_repo.define_singleton_method(:load_entries) { [known] }
    provider_entries = [{ imdb_id: 'tt4', title: 'English Title', source: 'omdb' }]

    with_fake_calendar_repository(fake_repo) do
      merged = Daemon.send(:merge_calendar_search_results, provider_entries, 'titre', nil, nil)

      assert_equal ['Titre local'], merged.map { |entry| entry[:title] }
    end
  end

  def test_calendar_search_merge_filters_local_matches_by_year
    entries = [
      { imdb_id: 'tt1', title: 'Remake', type: 'movie', year: 2025 },
      { imdb_id: 'tt2', title: 'Remake', type: 'movie', year: 1990 }
    ]
    fake_repo = Object.new
    fake_repo.define_singleton_method(:entries) { |_filters| { entries: entries } }
    fake_repo.define_singleton_method(:load_entries) { entries }

    with_fake_calendar_repository(fake_repo) do
      merged = Daemon.send(:merge_calendar_search_results, [], 'remake', 2025, nil)

      assert_equal ['tt1'], merged.map { |entry| entry[:imdb_id] }
    end
  end
end
