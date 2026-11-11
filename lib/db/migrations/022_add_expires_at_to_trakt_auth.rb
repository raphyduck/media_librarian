# frozen_string_literal: true

# La colonne expires_at est fournie avec le jeton Trakt et enregistrée par
# persist_trakt_token (app/daemon.rb); le schéma ne la créait pas, d'où
# « table trakt_auth has no column named expires_at ».
Sequel.migration do
  up do
    unless schema(:trakt_auth).map(&:first).include?(:expires_at)
      alter_table(:trakt_auth) do
        add_column :expires_at, Integer
      end
    end
  end

  down do
    if schema(:trakt_auth).map(&:first).include?(:expires_at)
      alter_table(:trakt_auth) do
        drop_column :expires_at
      end
    end
  end
end
