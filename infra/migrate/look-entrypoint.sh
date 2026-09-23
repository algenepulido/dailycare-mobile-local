#!/usr/bin/env bash
set -euo pipefail
export PGHOST="/cloudsql/${INSTANCE_CONNECTION_NAME}" PGUSER="$DB_USER" PGDATABASE="$DB_NAME"
until psql -c 'SELECT 1' >/dev/null 2>&1; do sleep 2; done
psql -c "SELECT email, left(password_hash, 30) AS hash, deactivated_at IS NULL AS active FROM users"
psql -c "SELECT count(*) AS residents FROM residents"
psql -c "SELECT count(*) AS assignments FROM assignments"
psql -c "SELECT 'stored hash matches the one we set: ' ||
         (password_hash = :'h')::text FROM users WHERE email='nurse@cedar.test'" -v h="$SEED_HASH"
