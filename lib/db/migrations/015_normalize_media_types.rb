# frozen_string_literal: true

Sequel.migration do
  up do
    %i[local_media calendar_entries].each do |table|
      next unless table_exists?(table)

      dataset = self[table]
      dataset.where(Sequel.function(:lower, :media_type) => %w[movies movie]).update(media_type: 'movie')
      dataset.where(Sequel.function(:lower, :media_type) => %w[shows show tv series]).update(media_type: 'show')
    end
  end

  down do
    # no-op
  end
end
