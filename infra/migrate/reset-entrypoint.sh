#!/usr/bin/env bash
#
# Put the database back to just the model, with nothing in it.
#
# For dev, where the one rule is that nothing real is ever in it - so this is safe by
# definition, and it exists because a verification run of mine left every suite's fixtures
# behind in the database the application uses.
#
# Not for staging and not for production. It drops the schema.
set -euo pipefail
export PGHOST="/cloudsql/${INSTANCE_CONNECTION_NAME}" PGUSER="$DB_USER" PGDATABASE="$DB_NAME"
until psql -c 'SELECT 1' >/dev/null 2>&1; do sleep 2; done

if [ "${GCP_ENV:-}" != "dev" ]; then
  echo "refusing: this drops the schema and is for dev only, not ${GCP_ENV:-unset}" >&2
  exit 1
fi

echo "what is there now:"
psql -c "SELECT count(*) AS users FROM users" || true

psql -v ON_ERROR_STOP=1 -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"
psql -v ON_ERROR_STOP=1 -c "GRANT USAGE ON SCHEMA public TO dailycare_app, dailycare_retention, dailycare_integration, dailycare_backup;"
echo "schema dropped and recreated"

cd /model && ./migrate.sh -d "$DB_NAME" --with-roles
psql -v ON_ERROR_STOP=1 \
  -c "SET dailycare.project = '${GCP_PROJECT}'; SET dailycare.env = '${GCP_ENV}';" \
  -f /model/cloudsql-iam.sql
echo "model applied and IAM users granted"
