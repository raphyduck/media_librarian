# frozen_string_literal: true

module MediaLibrarian
  # Shared IMDb identifier parsing/validation. Used both by the HTTP calendar
  # import (Daemon) and the calendar feed hydration (CalendarFeedService) so the
  # two can never drift — they previously kept byte-identical normalizers and a
  # divergent validity regex (anchored vs unanchored).
  module ImdbIdentifier
    module_function

    # Canonical IMDb id: "tt" followed by digits, nothing else.
    IMDB_ID_PATTERN = /\Att\d+\z/i

    def imdb_identifier?(value)
      value.to_s.match?(IMDB_ID_PATTERN)
    end

    # Coerce a raw id ("tt1234567", "1234567", "imdb1234567") to "tt<digits>".
    # Returns the stripped token unchanged when it is not all digits, or '' when
    # blank.
    def normalize_identifier(value)
      token = value.to_s.strip
      return '' if token.empty?

      digits = token.sub(/\A(?:imdb|tt)/i, '')
      return token unless digits.match?(/\A\d+\z/)

      "tt#{digits}"
    end
  end
end
