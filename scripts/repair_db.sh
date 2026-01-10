#!/usr/bin/env bash
set -euo pipefail

DB_PATH=${1:-librarian.db}
RECOVERED_DB="${DB_PATH%.db}.recovered.db"
TIMESTAMP=$(date +%Y%m%d%H%M%S)

log() {
  printf '[repair_db] %s\n' "$*"
}

if ! command -v sqlite3 >/dev/null 2>&1; then
  log "sqlite3 not found in PATH"
  exit 1
fi

if [[ ! -f "$DB_PATH" ]]; then
  log "Database not found: $DB_PATH"
  exit 1
fi

WAL_FILE="$DB_PATH-wal"
SHM_FILE="$DB_PATH-shm"

if [[ -f "$WAL_FILE" || -f "$SHM_FILE" ]]; then
  log "WAL/SHM detected. Stop the app for a consistent copy or allow checkpoint."
  sqlite3 "$DB_PATH" "PRAGMA wal_checkpoint(TRUNCATE);" || log "WAL checkpoint failed; proceeding may be unsafe."
fi

log "Recovering database: $DB_PATH -> $RECOVERED_DB"
sqlite3 "$DB_PATH" ".recover" | sqlite3 "$RECOVERED_DB"

log "Running integrity_check on recovered DB"
INTEGRITY=$(sqlite3 "$RECOVERED_DB" "PRAGMA integrity_check;")
if [[ "$INTEGRITY" != "ok" ]]; then
  log "Integrity check failed: $INTEGRITY"
  exit 1
fi

CORRUPT_DB="$DB_PATH.corrupt-$TIMESTAMP"
log "Swapping databases (keeping corrupted copy at $CORRUPT_DB)"
mv "$DB_PATH" "$CORRUPT_DB"
mv "$RECOVERED_DB" "$DB_PATH"

if [[ -f "$WAL_FILE" ]]; then
  mv "$WAL_FILE" "$WAL_FILE.corrupt-$TIMESTAMP"
fi
if [[ -f "$SHM_FILE" ]]; then
  mv "$SHM_FILE" "$SHM_FILE.corrupt-$TIMESTAMP"
fi

log "Repair complete"
