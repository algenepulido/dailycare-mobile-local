#!/usr/bin/env bash
#
# Apply the model to a database and record what was applied.
#
#   ./migrate.sh -d dailycare
#   ./migrate.sh -d dailycare --with-roles     also creates the four application roles
#
# Files come from model.list, in that order, and each one is applied at most once. What was
# applied is recorded in schema_migrations with the sha256 of the file, so a file that is
# edited after it has been applied stops the run rather than being silently skipped or
# silently re-run. Editing an applied file is how a database ends up different from the one
# the checks passed against, which is the whole thing this directory exists to prevent.
#
# verify.sh builds its suite databases with this script, so the database a check runs
# against and the database that gets deployed are built by the same code.
#
# --with-roles applies roles.sql first. That needs a login that may create roles; nothing
# else here does. Kept behind a flag so the elevated step is a decision rather than a
# side effect of running a migration.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DB=""
WITH_ROLES=0
while [ $# -gt 0 ]; do
  case "$1" in
    -d|--database) DB="${2:-}"; shift 2 ;;
    --with-roles)  WITH_ROLES=1; shift ;;
    -h|--help)     sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$DB" ] || { echo "which database? ./migrate.sh -d <name>" >&2; exit 2; }

command -v psql >/dev/null || { echo "psql is not on the path" >&2; exit 1; }

ERRLOG="$(mktemp -t dc-migrate-XXXXXX)"
trap 'rm -f "$ERRLOG"' EXIT

q () { psql -q -v ON_ERROR_STOP=1 -d "$DB" "$@"; }

# The list is the source of truth, and a model file that nobody added to it would never be
# applied and never be checked. So the list is compared against what is actually on disk in
# both directions before anything is applied.
mapfile -t WANTED < <(grep -v '^#' "$HERE/model.list" | grep -v '^[[:space:]]*$')
missing=0
for f in "${WANTED[@]}"; do
  [ -f "$HERE/$f" ] || { echo "model.list names $f and it is not here" >&2; missing=1; }
done
for f in "$HERE"/*.sql; do
  b="$(basename "$f")"
  case "$b" in *-invariants.sql|roles.sql|checks-support.sql) continue ;; esac
  printf '%s\n' "${WANTED[@]}" | grep -qx "$b" || {
    echo "$b is in this directory and not in model.list, so it would never be applied" >&2
    missing=1; }
done
[ "$missing" = 0 ] || exit 1

if [ "$WITH_ROLES" = 1 ]; then
  if ! psql -q -v ON_ERROR_STOP=1 -d postgres -f "$HERE/roles.sql" >/dev/null 2>"$ERRLOG"; then
    echo "could not create the application roles:" >&2
    grep -E 'ERROR|HINT' "$ERRLOG" | sed 's/^/  /' >&2
    exit 1
  fi
  echo "  roles.sql                      applied"
fi

q <<'SQL' >/dev/null 2>"$ERRLOG" || { echo "could not record migrations:" >&2; grep ERROR "$ERRLOG" >&2; exit 1; }
CREATE TABLE IF NOT EXISTS schema_migrations (
  position    integer     PRIMARY KEY,
  filename    text        NOT NULL UNIQUE,
  sha256      text        NOT NULL,
  applied_at  timestamptz NOT NULL DEFAULT now(),
  applied_by  text        NOT NULL DEFAULT current_user
);
COMMENT ON TABLE schema_migrations IS
  'What migrate.sh has applied to this database. The sha256 is of the file as applied, so a
   database can say whether it is the one the checks passed against.';
SQL

applied=0; skipped=0; pos=0
for f in "${WANTED[@]}"; do
  pos=$((pos+1))
  sha="$(sha256sum "$HERE/$f" | cut -c1-64)"
  was="$(psql -At -d "$DB" -c "SELECT sha256 FROM schema_migrations WHERE filename = '$f'" 2>/dev/null)"

  if [ -n "$was" ]; then
    if [ "$was" = "$sha" ]; then
      skipped=$((skipped+1)); continue
    fi
    echo "$f was applied to $DB and has changed since." >&2
    echo "  applied: $was" >&2
    echo "  on disk: $sha" >&2
    echo "Add a new file rather than editing one that is already in a database." >&2
    exit 1
  fi

  # The file and its record go in together, so a failure leaves neither.
  { cat "$HERE/$f"
    printf "\nINSERT INTO schema_migrations (position, filename, sha256) VALUES (%d, '%s', '%s');\n" \
      "$pos" "$f" "$sha"
  } | psql -q -1 -v ON_ERROR_STOP=1 -d "$DB" >/dev/null 2>"$ERRLOG" || {
    echo "could not apply $f:" >&2
    grep -E 'ERROR|DETAIL|HINT' "$ERRLOG" | head -5 | sed 's/^/  /' >&2
    exit 1; }
  applied=$((applied+1))
done

printf '  %-30s %d applied, %d already there\n' "$DB" "$applied" "$skipped"

if [ "$WITH_ROLES" = 1 ] && [ "$applied" -gt 0 ]; then
  cat <<'NOTE'

  roles.sql needed an elevated login and nothing after this does. If that login was handed
  over for this one run, rotate it now rather than later:

    gcloud sql users set-password postgres --instance=$INSTANCE --prompt-for-password
NOTE
fi
