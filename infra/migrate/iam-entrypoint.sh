#!/usr/bin/env bash
# Grants each Cloud SQL IAM user the model role it corresponds to. Runs once per instance.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/connect.sh"
psql -v ON_ERROR_STOP=1 \
  -c "SET dailycare.project = '${GCP_PROJECT}'; SET dailycare.env = '${GCP_ENV}';" \
  -f /model/cloudsql-iam.sql
echo
psql -c "SELECT r.rolname AS iam_user, g.rolname AS granted
         FROM pg_auth_members m
         JOIN pg_roles r ON r.oid = m.member
         JOIN pg_roles g ON g.oid = m.roleid
         WHERE r.rolname LIKE 'dc-%' ORDER BY r.rolname"
