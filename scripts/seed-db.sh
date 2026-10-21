#!/usr/bin/env bash
# Apply the domain schema (and optionally the demo seed) to RDS PostgreSQL.
# Automates the manual psql run of docs/infra-aws-consola.md §9.3 so that a
# deploy leaves the database ready without anyone opening a tunnel.
#
# Safe to run on every deploy and from every ASG instance at the same time:
# both SQL files are idempotent, and a PostgreSQL advisory lock serialises
# concurrent runs — plain CREATE TABLE IF NOT EXISTS can still collide on the
# system catalogue when two sessions race, which is exactly what two instances
# booting together would do.
#
# The connection comes from the standard PG* variables. On an app instance they
# are already in /etc/snowball.env; locally, export them first (or open the
# tunnel of §9.3 and use PGHOST=localhost PGPORT=15432).
#
# Usage:
#   scripts/seed-db.sh                    # schema + demo seed, SQL from ./infra/sql
#   scripts/seed-db.sh --schema-only      # no demo data (see the warning below)
#   scripts/seed-db.sh --bucket snowball-artifacts-xyz
#   scripts/seed-db.sh --sql-dir /opt/snowball/sql
#
# WARNING: seed.sql ends with ON CONFLICT (email) DO UPDATE SET password_hash,
# so running it resets the three demo users' passwords to the values documented
# in §9.3. Once real users exist, redeploy with --schema-only.
set -euo pipefail

SQL_DIR="infra/sql"
BUCKET=""
SCHEMA_ONLY=false
WAIT_SECONDS="${WAIT_SECONDS:-180}"

# Arbitrary but fixed: every instance must ask for the same lock for the
# serialisation to mean anything. Advisory locks live outside the data, so
# nothing here is written to the database.
LOCK_KEY=918273645

while [[ $# -gt 0 ]]; do
  case "$1" in
    --schema-only) SCHEMA_ONLY=true; shift ;;
    --sql-dir)     SQL_DIR="${2:?--sql-dir needs a directory}"; shift 2 ;;
    --bucket)      BUCKET="${2:?--bucket needs a bucket name}"; shift 2 ;;
    -h|--help)     sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 1 ;;
  esac
done

: "${PGHOST:?PGHOST is not set — source /etc/snowball.env, or export PG* by hand}"
: "${PGPASSWORD:?PGPASSWORD is not set — source /etc/snowball.env, or export PG* by hand}"
export PGDATABASE="${PGDATABASE:-snowball}"
export PGUSER="${PGUSER:-snowball}"
export PGPORT="${PGPORT:-5432}"
# RDS always offers TLS; the API does the same in packages/api/src/data.ts.
export PGSSLMODE="${PGSSLMODE:-require}"

SUDO=""
if [[ $EUID -ne 0 ]] && command -v sudo >/dev/null; then
  SUDO="sudo"
fi

if ! command -v psql >/dev/null; then
  if command -v dnf >/dev/null; then
    # Amazon Linux 2023 ships the client on its own, apart from the server.
    echo "psql not found, installing the PostgreSQL client..."
    $SUDO dnf install -y postgresql15 >/dev/null
  else
    echo "psql not found and this is not a dnf system." >&2
    echo "Install the PostgreSQL client and re-run (on Windows: the psql that" >&2
    echo "comes with the PostgreSQL installer, or run this script on the instance)." >&2
    exit 1
  fi
fi

if [[ -n "$BUCKET" ]]; then
  SQL_DIR=$(mktemp -d)
  trap 'rm -rf "$SQL_DIR"' EXIT
  echo "downloading SQL from s3://$BUCKET/ ..."
  aws s3 cp "s3://$BUCKET/schema.sql" "$SQL_DIR/schema.sql" >/dev/null
  aws s3 cp "s3://$BUCKET/seed.sql"   "$SQL_DIR/seed.sql"   >/dev/null
fi

FILES=(-f "$SQL_DIR/schema.sql")
WHAT="schema"
if [[ $SCHEMA_ONLY == false ]]; then
  FILES+=(-f "$SQL_DIR/seed.sql")
  WHAT="schema + seed"
fi

for i in "${!FILES[@]}"; do
  [[ ${FILES[$i]} == -f ]] && continue
  [[ -r "${FILES[$i]}" ]] || { echo "cannot read ${FILES[$i]}" >&2; exit 1; }
done

# At boot the instance can be ready before RDS finishes failing over or
# resolving, so wait instead of dying on the first refused connection.
echo "waiting for $PGHOST:$PGPORT (up to ${WAIT_SECONDS}s)..."
deadline=$(( $(date +%s) + WAIT_SECONDS ))
until pg_isready -q; do
  if [[ $(date +%s) -ge $deadline ]]; then
    echo "database unreachable after ${WAIT_SECONDS}s" >&2
    echo "from an app instance this should work; from the bastion it never will —" >&2
    echo "sg-db only accepts sg-app (see docs/infra-aws-consola.md §2.1)" >&2
    exit 1
  fi
  sleep 5
done

# -c and -f share one session, so the advisory lock taken first is still held
# while the files run, and is released when psql exits (even on error).
echo "applying $WHAT..."
psql --quiet -v ON_ERROR_STOP=1 \
  -c "SELECT pg_advisory_lock($LOCK_KEY);" \
  "${FILES[@]}" >/dev/null

psql -Atq -c "SELECT 'ok: ' || (SELECT count(*) FROM units) || ' units, '
                            || (SELECT count(*) FROM users) || ' users, '
                            || (SELECT count(*) FROM device_config) || ' configs'"
