# frozen_string_literal: true

# Torrent queue HTTP endpoints for the daemon control server: list pending,
# validate, and delete, plus their snapshot/format/identifier helpers. Every
# operation acts on the 'torrents' database table only — never on media files.
# Reopens Daemon's singleton class so these methods stay byte-for-byte
# identical to their prior inline definitions; extracted purely to shrink
# app/daemon.rb. Zeitwerk is told to ignore this file (see
# Application#setup_loader) because it reopens Daemon rather than defining a
# Daemon::TorrentEndpoints constant.

class Daemon
  class << self
    def handle_pending_torrents_request(req, res)
      return method_not_allowed(res, 'GET') unless req.request_method == 'GET'

      json_response(res, body: pending_torrents_snapshot)
    rescue StandardError => e
      error_response(res, status: 500, message: e.message)
    end

    def handle_validate_torrent_request(req, res)
      return method_not_allowed(res, 'POST') unless req.request_method == 'POST'

      identifier = extract_torrent_identifier(parse_payload(req))
      return error_response(res, status: 400, message: 'Identifiant de torrent manquant') unless identifier

      torrent = find_pending_torrent(identifier)
      return error_response(res, status: 404, message: 'Torrent introuvable ou déjà validé') unless torrent

      updated = app.db.update_rows('torrents', { status: 2 }, { status: 1, name: torrent[:name] })
      return error_response(res, status: 500, message: 'Impossible de valider le torrent') unless updated.to_i.positive?

      json_response(res, body: { 'status' => 'validated', 'identifier' => torrent[:identifier] || torrent[:name] })
    rescue StandardError => e
      error_response(res, status: 500, message: e.message)
    end

    def handle_delete_torrent_request(req, res)
      return method_not_allowed(res, 'POST') unless req.request_method == 'POST'

      identifier = extract_torrent_identifier(parse_payload(req))
      return error_response(res, status: 400, message: 'Identifiant de torrent manquant') unless identifier

      deleted = app.db.delete_rows('torrents', { status: [1, 2], identifier: identifier })
      deleted = app.db.delete_rows('torrents', { status: [1, 2], name: identifier }) unless deleted.to_i.positive?
      return error_response(res, status: 404, message: 'Torrent introuvable') unless deleted.to_i.positive?

      json_response(res, body: { 'status' => 'deleted', 'identifier' => identifier })
    rescue StandardError => e
      error_response(res, status: 500, message: e.message)
    end

    def pending_torrents_snapshot
      rows = app.db.get_rows('torrents', { status: [1, 2] })
      rows.each_with_object({ validation: [], downloads: [] }) do |row, memo|
        entry = format_pending_torrent(row)
        next unless entry

        (row[:status].to_i == 1 ? memo[:validation] : memo[:downloads]) << entry
      end
    rescue StandardError => e
      app.speaker.tell_error(e, 'pending_torrents_snapshot') rescue nil
      { validation: [], downloads: [] }
    end

    def format_pending_torrent(row)
      attributes = row[:tattributes]
      attributes = Cache.object_unpack(attributes) unless attributes.is_a?(Hash)
      attributes = {} unless attributes.is_a?(Hash)

      {
        name: row[:name].to_s,
        tracker: attributes[:tracker],
        category: attributes[:category],
        waiting_until: row[:waiting_until],
        created_at: row[:created_at],
        identifier: row[:identifier],
        status: row[:status].to_i,
      }.compact
    end

    # Attach each watchlist entry's pending torrents (status 1/2), ranked the
    # same way promote_ready_downloads picks a release: smallest total
    # timeframe (closest to the target quality) first, then largest size.
    # Pending torrents that belong to no watchlist entry (e.g. TV episodes)
    # are returned separately, grouped by identifier, so the UI can still
    # surface them in the merged view.
    def decorate_watchlist_entries(entries)
      rows = app.db.get_rows('torrents', { status: [1, 2] }) || []
      formatted = rows.filter_map { |row| format_watchlist_torrent(row) }
      claimed = []
      decorated = Array(entries).map do |entry|
        torrents = formatted.select { |torrent| torrent_matches_watchlist_entry?(torrent, entry) }
        claimed.concat(torrents)
        entry.merge(torrents: sort_watchlist_torrents(torrents))
      end
      orphans = (formatted - claimed).group_by { |torrent| torrent[:identifier].to_s }.map do |identifier, group|
        {
          identifier: identifier,
          category: group.first[:category],
          torrents: sort_watchlist_torrents(group),
        }
      end
      [decorated, orphans]
    rescue StandardError => e
      app.speaker.tell_error(e, 'decorate_watchlist_entries') rescue nil
      [Array(entries).map { |entry| entry.merge(torrents: []) }, []]
    end

    def format_watchlist_torrent(row)
      attributes = row[:tattributes]
      attributes = Cache.object_unpack(attributes) unless attributes.is_a?(Hash)
      attributes = {} unless attributes.is_a?(Hash)

      {
        name: row[:name].to_s,
        tracker: attributes[:tracker],
        category: attributes[:category],
        size: attributes[:size].to_f,
        timeframe_total: attributes[:timeframe_quality].to_i + attributes[:timeframe_tracker].to_i + attributes[:timeframe_size].to_i,
        waiting_until: row[:waiting_until],
        created_at: row[:created_at],
        identifier: row[:identifier].to_s,
        status: row[:status].to_i,
      }
    end

    # Movie identifiers are "movie<OriginalTitle> (<year>)<year>" and watchlist
    # entries carry that same calendar title, so a case-insensitive title
    # inclusion plus a year check reliably pairs them.
    def torrent_matches_watchlist_entry?(torrent, entry)
      identifier = torrent[:identifier].to_s.downcase
      return false if identifier.empty?

      title = (entry[:title] || entry['title']).to_s.strip.downcase
      return false if title.empty? || !identifier.include?(title)

      year = (entry[:year] || entry['year']).to_i
      year.zero? || identifier.include?(year.to_s)
    end

    def sort_watchlist_torrents(torrents)
      torrents.sort_by { |torrent| [torrent[:timeframe_total], -torrent[:size]] }
    end

    def extract_torrent_identifier(payload)
      return nil unless payload.is_a?(Hash)

      [payload['identifier'], payload['name']].map { |value| value.to_s.strip }.find { |value| !value.empty? }
    end

    def find_pending_torrent(identifier)
      db = app.respond_to?(:db) ? app.db : nil
      return nil unless db

      db.get_rows('torrents', { status: 1, identifier: identifier }).first ||
        db.get_rows('torrents', { status: 1, name: identifier }).first
    end
  end
end
