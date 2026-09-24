#!/usr/bin/env bash
#
# What the Cloud Run job runs. Connects through the Cloud SQL socket the runtime provides,
# applies the model with migrate.sh, and prints what it did.
#
# It takes no arguments and makes no decisions: everything is an environment variable set
# on the job, so what ran is visible in the job's definition rather than in whoever
# launched it.

set -euo pipefail

: "${INSTANCE_CONNECTION_NAME:?the job needs INSTANCE_CONNECTION_NAME}"
: "${DB_NAME:=dailycare}"
: "${DB_USER:?the job needs DB_USER}"
: "${WITH_ROLES:=0}"

# Cloud Run mounts the Cloud SQL socket here when the instance is attached to the job.
. "$(dirname "${BASH_SOURCE[0]}")/connect.sh"
export PGUSER="$DB_USER"
export PGDATABASE="$DB_NAME"
# PGPASSWORD comes from a secret the job mounts, or is absent for IAM authentication.

echo "applying the model to ${DB_NAME} on ${INSTANCE_CONNECTION_NAME} as ${DB_USER}"

until psql -c 'SELECT 1' >/dev/null 2>&1; do
  echo "waiting for the socket"
  sleep 2
done

if [ "$WITH_ROLES" = "1" ]; then
  /model/migrate.sh -d "$DB_NAME" --with-roles
else
  /model/migrate.sh -d "$DB_NAME"
fi

echo
echo "what is in the database now:"
psql -c "SELECT position, filename, left(sha256, 12) AS sha, applied_by
         FROM schema_migrations ORDER BY position"
