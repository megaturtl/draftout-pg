#!/usr/bin/env bash
# Brings up a local Postgres cluster and loads the latest draftout dump.
# All state lives under `./.pg` (delete to reset).
# Configuration comes entirely from the environment set by `flake.nix`.
set -euo pipefail

# Fail with a clear message if a required setting is missing.
: "${PGUSER:?} ${PGPASSWORD:?} ${PGDATABASE:?} ${PGPORT:?} ${MANIFEST_URL:?}"
VIEWS_FILE="${VIEWS_FILE:-}"

PG_DIR="$PWD/.pg"
export PGDATA="$PG_DIR/data"
export PGHOST="localhost"
export PGPORT
# Records the sha256 of currently loaded dump so it only reloads on change.
SHA_MARKER="$PG_DIR/.loaded_sha"

mkdir -p "$PG_DIR"

# 1. Initialise the cluster once.
if [ ! -d "$PGDATA" ]; then
  echo ">> initialising postgres cluster"
  initdb \
    --username="$PGUSER" \
    --pwfile=<(printf '%s' "$PGPASSWORD") \
    --auth=trust \
    --encoding=UTF8 \
    "$PGDATA" >/dev/null
fi

# 2. Start the server on localhost TCP.
if ! pg_ctl status -D "$PGDATA" >/dev/null 2>&1; then
  echo ">> starting postgres on localhost:$PGPORT"
  pg_ctl start -D "$PGDATA" \
    -o "-c listen_addresses=localhost -p $PGPORT -c unix_socket_directories=$PG_DIR" \
    -w -l "$PG_DIR/server.log" >/dev/null
fi

# 3. Look up the latest relational dump from the manifest. dumps[0] is the newest.
echo ">> checking manifest for latest dump"
MANIFEST=$(curl -fsSL "$MANIFEST_URL")
read -r DUMP_URL DUMP_SHA DUMP_MIB < <(jq -r \
  '.dumps[0].files[] | select(.kind == "relational_sql") | "\(.url) \(.sha256) \(.size/1048576|floor)"' \
  <<<"$MANIFEST")
if [ -z "$DUMP_URL" ] || [ "$DUMP_URL" = "null" ]; then
  echo "!! no relational_sql dump found in the manifest" >&2
  exit 1
fi

db_exists() { psql -lqt | cut -d '|' -f 1 | grep -qw "$PGDATABASE"; }

# 4. Reload only when the database is missing or the dump has changed.
if db_exists && [ "$(cat "$SHA_MARKER" 2>/dev/null)" = "$DUMP_SHA" ]; then
  echo ">> $PGDATABASE already up to date (sha ${DUMP_SHA:0:12})"
else
  echo ">> new dump available (sha ${DUMP_SHA:0:12}), reloading $PGDATABASE"

  # Start from a clean database and rebuild.
  # --force evicts any open sessions (e.g. an IDE connection) so the drop succeeds.
  dropdb --if-exists --force "$PGDATABASE"
  createdb "$PGDATABASE"

  # The dump expects pg_trgm (used by a player-name index).
  psql --quiet --dbname="$PGDATABASE" -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;" >/dev/null 2>&1 || true

  # Download to a temp file that gets cleaned up even on failure.
  DUMP_TMP=$(mktemp "$PG_DIR/dump.XXXXXX.sql.gz")
  trap 'rm -f "$DUMP_TMP"' EXIT

  echo ">> downloading dump (~${DUMP_MIB} MiB)"
  curl -fSL "$DUMP_URL" -o "$DUMP_TMP"

  echo ">> verifying checksum"
  echo "${DUMP_SHA}  ${DUMP_TMP}" | sha256sum -c - >/dev/null

  echo ">> loading dump into $PGDATABASE (this may take a while)"
  gzip -dc "$DUMP_TMP" | psql --quiet --dbname="$PGDATABASE" \
    --set ON_ERROR_STOP=0 >/dev/null

  # Recreate views.
  if [ -n "$VIEWS_FILE" ] && [ -f "$PWD/$VIEWS_FILE" ]; then
    echo ">> (re)creating views from $VIEWS_FILE"
    psql --quiet --dbname="$PGDATABASE" -f "$PWD/$VIEWS_FILE" >/dev/null
  fi

  echo "$DUMP_SHA" > "$SHA_MARKER"
  echo ">> load complete"  # DUMP_TMP gets removed by the EXIT trap
fi

echo ""
echo "postgres ready:  host=localhost  port=$PGPORT  db=$PGDATABASE  user=$PGUSER"
echo ""