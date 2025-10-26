#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
require_relative '../lib/media_librarian/application'
require_relative '../lib/cache'

app = MediaLibrarian.application
db = app.db

def download_url?(url)
  url = url.to_s.strip
  return false if url.empty?

  return true if url.start_with?('magnet:')
  return true if url.match?(/\.(torrent|nzb)(?:\?.*)?\z/i)

  url.match?(/(\/download\b|download\.php|enclosure|getnzb|getTorrent|action=download)/i)
end

fixed = 0

db.get_rows('torrents', {}, { 'status >' => 0 }).each do |row|
  next unless row[:status].to_i > 0
  attrs = begin
    Cache.object_unpack(row[:tattributes])
  rescue StandardError
    nil
  end
  next unless attrs.is_a?(Hash)

  attrs = attrs.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
  link = attrs[:link].to_s
  torrent_link = attrs[:torrent_link].to_s
  next if link.empty? || torrent_link.empty?
  next unless download_url?(link) && !download_url?(torrent_link)

  puts "---"
  puts "Fixing '#{row[:name]}' (status=#{row[:status]})"
  puts "  record: #{row.inspect}"
  puts "  before: link=#{link.inspect}"
  puts "          torrent_link=#{torrent_link.inspect}"
  attrs[:link], attrs[:torrent_link] = torrent_link, link
  db.update_rows('torrents', { tattributes: Cache.object_pack(attrs) }, { name: row[:name] })
  puts "  after:  link=#{attrs[:link].inspect}"
  puts "          torrent_link=#{attrs[:torrent_link].inspect}"
  fixed += 1
end

puts "Fixed #{fixed} torrent#{'s' unless fixed == 1}."
