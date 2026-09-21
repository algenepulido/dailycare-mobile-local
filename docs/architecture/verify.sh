#!/usr/bin/env bash
#
# Verify the whole model.
#
# Each suite seeds its own fixtures and then tries to violate them, so each one needs a
# database of its own. That is what this does: build, apply, run, drop, repeat. Nothing is
# left behind and nothing existing is touched.
#
#   ./verify.sh
#
# Needs psql, createdb and dropdb on the path, a role that may create databases, and the
# three application roles from roles.sql (which needs a role that may create roles, once).
#
# Exit code is 0 only if every check in every suite passed.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB_PREFIX="${DB_PREFIX:-dc_verify}"

for tool in psql createdb dropdb; do
  command -v "$tool" >/dev/null || {
    echo "$tool is not on the path. This needs the PostgreSQL client tools and a role that" >&2
    echo "may create databases. If you would rather not install anything, review.sh does the" >&2
    echo "same thing inside a throwaway container and needs only Docker." >&2
    exit 1; }
done

SUITES=(schema-invariants.sql access-invariants.sql audit-invariants.sql
        retention-invariants.sql environment-invariants.sql vendor-invariants.sql
        backup-invariants.sql logging-invariants.sql auth-invariants.sql
        secrets-invariants.sql boundary-invariants.sql incident-invariants.sql
        iam-invariants.sql migration-invariants.sql)

TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_ERR=0

ERRLOG="$(mktemp -t dc-verify-XXXXXX)"
trap 'rm -f "$ERRLOG"' EXIT

# The roles are cluster-wide and created once.
if ! psql -q -v ON_ERROR_STOP=1 -d postgres -f "$HERE/roles.sql" >/dev/null 2>"$ERRLOG"; then
  echo "could not create the application roles:" >&2
  grep -E 'ERROR|HINT' "$ERRLOG" | sed 's/^/  /' >&2
  exit 1
fi

for suite in "${SUITES[@]}"; do
  db="${DB_PREFIX}_$(basename "$suite" -invariants.sql)"
  dropdb --if-exists "$db" >/dev/null 2>&1
  createdb "$db" >/dev/null 2>&1 || { echo "could not create $db" >&2; exit 1; }

  # Built by the same script that deploys, so a check cannot pass against a database that
  # was assembled differently from the real one. checks-support.sql is not model - it is
  # the scaffolding the suites need - so it goes on afterwards.
  ok=1
  if ! "$HERE/migrate.sh" -d "$db" >/dev/null 2>"$ERRLOG"; then
    printf '%-32s could not migrate\n' "$suite"
    grep -E 'ERROR|HINT|has changed|not in model.list' "$ERRLOG" | head -4 | sed 's/^/    /'; ok=0
  elif ! psql -q -v ON_ERROR_STOP=1 -d "$db" -f "$HERE/checks-support.sql" >/dev/null 2>"$ERRLOG"; then
    printf '%-32s could not apply checks-support.sql\n' "$suite"
    grep -E 'ERROR|HINT' "$ERRLOG" | sed 's/^/    /'; ok=0
  fi
  [ "$ok" = 1 ] || { dropdb --if-exists "$db" >/dev/null 2>&1; TOTAL_ERR=$((TOTAL_ERR+1)); continue; }

  out="$(psql -d "$db" -f "$HERE/$suite" 2>&1)"
  p=$(printf '%s\n' "$out" | grep -cE '^(psql:.*NOTICE: *)?PASS ')
  f=$(printf '%s\n' "$out" | grep -cE '^(psql:.*NOTICE: *)?FAIL ')
  e=$(printf '%s\n' "$out" | grep -c 'ERROR')
  TOTAL_PASS=$((TOTAL_PASS+p)); TOTAL_FAIL=$((TOTAL_FAIL+f)); TOTAL_ERR=$((TOTAL_ERR+e))

  printf '%-32s PASS %-4s FAIL %-4s ERROR %s\n' "$suite" "$p" "$f" "$e"
  [ "$f" = 0 ] || printf '%s\n' "$out" | grep -E '^(psql:.*NOTICE: *)?FAIL ' | sed 's/^/    /'
  [ "$e" = 0 ] || printf '%s\n' "$out" | grep 'ERROR' | head -5 | sed 's/^/    /'

  dropdb --if-exists "$db" >/dev/null 2>&1
done

echo "─────────────────────────────────────────────────────────────"
printf 'TOTAL                            PASS %-4s FAIL %-4s ERROR %s\n' \
  "$TOTAL_PASS" "$TOTAL_FAIL" "$TOTAL_ERR"

[ "$TOTAL_FAIL" = 0 ] && [ "$TOTAL_ERR" = 0 ]
