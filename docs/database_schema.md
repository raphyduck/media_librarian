# Database schema

Regenerate with:
```sh
bundle exec ruby scripts/generate_database_schema.rb
```

## calendar_entries

| Column | Type | Null | Default | PK |
| --- | --- | --- | --- | --- |
| id | INTEGER | NO |  | YES |
| source | varchar(50) | NO |  |  |
| external_id | varchar(200) | NO |  |  |
| title | varchar(500) | NO |  |  |
| media_type | varchar(50) | NO |  |  |
| genres | TEXT | YES |  |  |
| languages | TEXT | YES |  |  |
| countries | TEXT | YES |  |  |
| rating | double precision | YES |  |  |
| release_date | date | YES |  |  |
| created_at | timestamp | YES |  |  |
| updated_at | timestamp | YES |  |  |
| poster_url | varchar(500) | YES |  |  |
| backdrop_url | varchar(500) | YES |  |  |
| ids | TEXT | YES |  |  |
| imdb_votes | INTEGER | YES |  |  |
| synopsis | TEXT | YES |  |  |
| imdb_id | varchar(50) | NO |  |  |

### Indexes

| Name | Columns | Unique |
| --- | --- | --- |
| idx_calendar_entries_imdb_id | imdb_id | YES |
| idx_calendar_entries_release_date | release_date | NO |

### Foreign keys (database)
_None_

### Foreign keys (logical)

| Column | References | Notes |
| --- | --- | --- |
| imdb_id | watchlist.imdb_id | Shared IMDb identifier for the same title. |
| imdb_id | local_media.imdb_id | Local media files for the same title. |

## local_media

| Column | Type | Null | Default | PK |
| --- | --- | --- | --- | --- |
| id | INTEGER | NO |  | YES |
| media_type | TEXT | NO |  |  |
| local_path | TEXT | NO |  |  |
| created_at | timestamp | YES |  |  |
| imdb_id | TEXT | YES |  |  |

### Indexes

| Name | Columns | Unique |
| --- | --- | --- |
| idx_local_media_type_imdb_id | media_type, imdb_id | YES |

### Foreign keys (database)
_None_

### Foreign keys (logical)

| Column | References | Notes |
| --- | --- | --- |
| imdb_id | calendar_entries.imdb_id | Calendar metadata for the same title. |
| imdb_id | watchlist.imdb_id | Watchlist entry for the same title. |

## metadata_search

| Column | Type | Null | Default | PK |
| --- | --- | --- | --- | --- |
| keywords | TEXT | NO |  |  |
| type | INTEGER | YES |  |  |
| result | TEXT | YES |  |  |
| created_at | timestamp | YES |  |  |

### Indexes

| Name | Columns | Unique |
| --- | --- | --- |
| idx_metadata_search_keywords_type | keywords, type | YES |

### Foreign keys (database)
_None_

### Foreign keys (logical)
_None_

## queues_state

| Column | Type | Null | Default | PK |
| --- | --- | --- | --- | --- |
| queue_name | varchar(200) | NO |  | YES |
| value | TEXT | YES |  |  |
| created_at | timestamp | YES |  |  |

### Indexes
_None_

### Foreign keys (database)
_None_

### Foreign keys (logical)
_None_

## schema_info

| Column | Type | Null | Default | PK |
| --- | --- | --- | --- | --- |
| version | INTEGER | NO | "0" |  |

### Indexes
_None_

### Foreign keys (database)
_None_

### Foreign keys (logical)
_None_

## torrents

| Column | Type | Null | Default | PK |
| --- | --- | --- | --- | --- |
| name | varchar(500) | NO |  | YES |
| identifier | TEXT | YES |  |  |
| identifiers | TEXT | YES |  |  |
| tattributes | TEXT | YES |  |  |
| created_at | timestamp | YES |  |  |
| updated_at | timestamp | YES |  |  |
| waiting_until | timestamp | YES |  |  |
| torrent_id | TEXT | YES |  |  |
| status | INTEGER | YES |  |  |

### Indexes

| Name | Columns | Unique |
| --- | --- | --- |
| idx_torrents_torrent_id | torrent_id | YES |

### Foreign keys (database)
_None_

### Foreign keys (logical)
_None_

## trakt_auth

| Column | Type | Null | Default | PK |
| --- | --- | --- | --- | --- |
| account | varchar(30) | NO |  | YES |
| access_token | varchar(200) | YES |  |  |
| token_type | varchar(200) | YES |  |  |
| refresh_token | varchar(200) | YES |  |  |
| scope | varchar(200) | YES |  |  |
| created_at | INTEGER | YES |  |  |
| expires_in | INTEGER | YES |  |  |

### Indexes
_None_

### Foreign keys (database)
_None_

### Foreign keys (logical)
_None_

## watchlist

| Column | Type | Null | Default | PK |
| --- | --- | --- | --- | --- |
| type | TEXT | NO |  |  |
| created_at | timestamp | YES |  |  |
| updated_at | timestamp | YES |  |  |
| imdb_id | TEXT | NO |  |  |

### Indexes

| Name | Columns | Unique |
| --- | --- | --- |
| idx_watchlist_imdb_type | imdb_id, type | YES |

### Foreign keys (database)
_None_

### Foreign keys (logical)

| Column | References | Notes |
| --- | --- | --- |
| imdb_id | calendar_entries.imdb_id | Calendar metadata for the same title. |
| imdb_id | local_media.imdb_id | Local media files for the same title. |
