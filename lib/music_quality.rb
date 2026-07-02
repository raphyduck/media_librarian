# frozen_string_literal: true

# Music release quality matching used by the music torrent search.
#
# Unlike the video quality system (Quality / Q_SORT), music quality is a single
# release-format choice (lossless vs lossy, bitrate). Each entry declares:
#   :label   - human readable name shown in the web UI
#   :match   - regexp the torrent name must match
#   :require - (optional) additional regexp that must also match
#   :reject  - (optional) regexp that must NOT match
module MusicQuality
  QUALITIES = {
    'flac' => {
      :label => 'FLAC (lossless)',
      :match => /\bflac\b/i
    },
    'flac24' => {
      :label => 'FLAC Hi-Res (24 bits)',
      :match => /\bflac\b/i,
      :require => /24[\s._-]?bit|\b24b\b|hi[\s._-]?res|hires|\b(?:96|176|192)[\s._-]?k?hz\b/i
    },
    'mp3_320' => {
      :label => 'MP3 320',
      :match => /\b320\b|320\s?kbps/i,
      :reject => /\bflac\b/i
    },
    'mp3_v0' => {
      :label => 'MP3 V0',
      :match => /\bv0\b/i,
      :reject => /\bflac\b/i
    }
  }.freeze

  module_function

  # Ordered list of {value, label} hashes for populating a UI dropdown.
  def options
    QUALITIES.map { |value, spec| { 'value' => value, 'label' => spec[:label] } }
  end

  def valid?(quality)
    QUALITIES.key?(quality.to_s)
  end

  def label(quality)
    spec = QUALITIES[quality.to_s]
    spec ? spec[:label] : quality.to_s
  end

  # Does a torrent name satisfy the requested quality?
  # A blank quality matches everything (no filtering).
  def matches?(name, quality)
    return true if quality.to_s.empty?
    spec = QUALITIES[quality.to_s]
    return true if spec.nil?
    name = name.to_s
    return false unless name.match?(spec[:match])
    return false if spec[:require] && !name.match?(spec[:require])
    return false if spec[:reject] && name.match?(spec[:reject])
    true
  end

  # Keep only the torrent results whose :name satisfies the requested quality.
  def filter(results, quality)
    return results if quality.to_s.empty?
    Array(results).select { |torrent| matches?(torrent[:name], quality) }
  end

  # Pick the best matching result for a quality: highest seeders first.
  def best(results, quality)
    filter(results, quality).max_by { |torrent| torrent[:seeders].to_i }
  end
end
