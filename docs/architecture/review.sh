#!/usr/bin/env bash
#
# Everything, in one command, with nothing installed but Docker.
#
#   ./review.sh
#
# Starts a throwaway PostgreSQL 14, runs all ten check suites and the restore drill inside
# it, and removes the container afterwards. Nothing touches anything on this machine.
#
# It runs as an ordinary database user rather than as a superuser, deliberately. A
# superuser bypasses row-level security entirely, so a suite run as one can report success
# while the policies under test were never consulted - and a managed instance, which is
# what production will be, gives nobody a superuser. If you would rather use your own
# PostgreSQL, see README.md; verify.sh is the same thing without the container.
#
# Exit code is 0 only if every check passed.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME="dailycare-review-$$"
IMAGE="postgres:14"

command -v docker >/dev/null || { echo "docker is not on the path" >&2; exit 1; }

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1; }
trap cleanup EXIT

echo "starting a throwaway $IMAGE"
docker run -d --name "$NAME" -e POSTGRES_PASSWORD=review \
  -v "$HERE":/sql:ro "$IMAGE" >/dev/null || exit 1

for _ in $(seq 1 60); do
  docker exec "$NAME" pg_isready -q 2>/dev/null && break
  sleep 1
done
docker exec "$NAME" pg_isready -q || { echo "the database never came up" >&2; exit 1; }

# An ordinary user: may create databases and roles, is not a superuser. The same shape as
# the administrative user on a managed instance.
docker exec -u postgres "$NAME" psql -q -c \
  "CREATE ROLE reviewer LOGIN CREATEDB CREATEROLE PASSWORD 'review';" >/dev/null

run() {
  docker exec -u postgres -w /sql \
    -e PGUSER=reviewer -e PGPASSWORD=review -e PGHOST=127.0.0.1 "$NAME" "$@"
}

echo ""
echo "── the checks, as somebody who is not a superuser"
run ./verify.sh
verified=$?

echo ""
echo "── the restore drill: a real dump, restored under another name"
run ./restore-drill.sh --build
drilled=$?

echo ""
if [ "$verified" = 0 ] && [ "$drilled" = 0 ]; then
  echo "everything passed."
else
  echo "something failed: verify.sh exited $verified, restore-drill.sh exited $drilled"
fi
[ "$verified" = 0 ] && [ "$drilled" = 0 ]
