#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
require_relative '../lib/media_librarian/application'
require_relative '../lib/cache'

unless defined?(SPACE_SUBSTITUTE) && defined?(VALID_VIDEO_EXT) && defined?(BASIC_EP_MATCH)
  require_relative '../init/global'
end

DOWNLOAD_RX = %r{(magnet:|\.torrent(\?.*)?\z|/download\b|download\.php|enclosure|getnzb|getTorrent|action=download)}i
def fix_torznab_links(db, out: $stdout)
  fixed = 0

  db.get_rows('torrents').each do |row|
    next unless row[:status].to_i.positive?
    attrs = begin
      Cache.object_unpack(row[:tattributes])
    rescue StandardError
      nil
    end
    next unless attrs.is_a?(Hash)

    attrs = attrs.each_with_object({}) { |(k, v), memo| memo[k.respond_to?(:to_sym) ? k.to_sym : k] = v }
    before_link = attrs[:link].to_s.strip
    before_torrent = attrs[:torrent_link].to_s.strip
    next if before_link.empty? && before_torrent.empty?
    next unless before_torrent.match?(DOWNLOAD_RX)
    next if before_link.match?(DOWNLOAD_RX)

    out.puts '---'
    out.puts "Fixing '#{row[:name]}' (status=#{row[:status]})"
    out.puts "  record: #{row.inspect}"
    out.puts "  before: link=#{before_link.inspect}"
    out.puts "          torrent_link=#{before_torrent.inspect}"

    attrs[:details_link] ||= before_link unless before_link.empty?
    attrs[:link] = before_torrent
    attrs[:torrent_link] = before_torrent
    db.update_rows('torrents', { tattributes: Cache.object_pack(attrs) }, { name: row[:name] })

    out.puts "  after:  link=#{attrs[:link].inspect}"
    out.puts "          torrent_link=#{attrs[:torrent_link].inspect}"
    out.puts "          details_link=#{attrs[:details_link].inspect}"
    fixed += 1
  end

  out.puts "Fixed #{fixed} torrent#{'s' unless fixed == 1}."
  fixed
end

if $PROGRAM_NAME == __FILE__
  app = MediaLibrarian.application
  fix_torznab_links(app.db)
end
