# frozen_string_literal: true

Sequel.migration do
  up do
    %i[local_media calendar_entries].each do |table|
      next unless table_exists?(table)

      dataset = self[table]
      if table == :local_media
        normalized_types = %w[movies movie shows show tv series]
        normalized = Sequel.case(
          {
            Sequel.lit("lower(media_type) IN ?", %w[movies movie]) => 'movie',
            Sequel.lit("lower(media_type) IN ?", %w[shows show tv series]) => 'show'
          },
          Sequel.function(:lower, :media_type)
        )
        candidates = dataset.where(Sequel.function(:lower, :media_type) => normalized_types)
        keep_ids = candidates.select(Sequel.function(:min, :id).as(:id)).group(:imdb_id, normalized)
        candidates.exclude(id: keep_ids).delete
      end

      dataset.where(Sequel.function(:lower, :media_type) => %w[movies movie]).update(media_type: 'movie')
      dataset.where(Sequel.function(:lower, :media_type) => %w[shows show tv series]).update(media_type: 'show')
    end
  end

  down do
    # no-op
  end
end
