#!/usr/bin/env bash
# Grants each Cloud SQL IAM user the model role it corresponds to. Runs once per instance.
set -euo pipefail
export PGHOST="/cloudsql/${INSTANCE_CONNECTION_NAME}" PGUSER="$DB_USER" PGDATABASE="$DB_NAME"
until psql -c 'SELECT 1' >/dev/null 2>&1; do sleep 2; done
psql -v ON_ERROR_STOP=1 \
  -c "SET dailycare.project = '${GCP_PROJECT}'; SET dailycare.env = '${GCP_ENV}';" \
  -f /model/cloudsql-iam.sql
echo
psql -c "SELECT r.rolname AS iam_user, g.rolname AS granted
         FROM pg_auth_members m
         JOIN pg_roles r ON r.oid = m.member
         JOIN pg_roles g ON g.oid = m.roleid
         WHERE r.rolname LIKE 'dc-%' ORDER BY r.rolname"
