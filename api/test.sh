#!/usr/bin/env bash
#
# Run the API tests against a real database with the model applied.
#
#   ./test.sh
#
# Builds a throwaway postgres:14, applies the model with the same migrate.sh that deploys,
# and connects as dailycare_app with a password - which is what Cloud Run will do until the
# instance carries cloudsql.iam_authentication. The role is NOLOGIN in roles.sql because
# nothing should be able to log in as it on a cluster where it was only created to be
# granted to; here it needs a password, and that is a property of this container rather
# than of the model, so it is set here and not there.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCH="$HERE/../docs/architecture"
NAME="dailycare-api-test"

docker rm -f "$NAME" >/dev/null 2>&1
docker run -d --rm --name "$NAME" -p 55432:5432 -e POSTGRES_PASSWORD=postgres \
  -v "$ARCH":/sql:ro postgres:14 >/dev/null || exit 1
trap 'docker rm -f "$NAME" >/dev/null 2>&1' EXIT

until docker logs "$NAME" 2>&1 | grep -q "PostgreSQL init process complete"; do sleep 1; done
until docker exec "$NAME" psql -U postgres -c "select 1" >/dev/null 2>&1; do sleep 1; done

docker exec -u postgres "$NAME" createdb dailycare || exit 1
docker exec -u postgres -w /sql "$NAME" ./migrate.sh -d dailycare --with-roles >/dev/null || {
  echo "the model would not apply" >&2; exit 1; }

# A password and LOGIN, for this container only.
docker exec -u postgres "$NAME" psql -q -d dailycare \
  -c "ALTER ROLE dailycare_app LOGIN PASSWORD 'test'" || exit 1

export DAILYCARE_TEST_DSN="postgres://dailycare_app:test@127.0.0.1:55432/dailycare?sslmode=disable"
cd "$HERE" && go test ./... "$@"
