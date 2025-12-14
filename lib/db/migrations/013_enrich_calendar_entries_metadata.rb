# frozen_string_literal: true

Sequel.migration do
  up do
    # Version 13 previously performed calendar entry enrichment as a data-only migration.
    # Keep this placeholder so databases already at version 13 remain in sync.
  end

  down do
    # No schema changes were introduced in version 13.
  end
end
