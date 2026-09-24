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

# The socket, the user, the database and either a password or a token. It also waits for
# the socket, which Cloud Run mounts when the instance is attached rather than when the
# container starts.
. "$(dirname "${BASH_SOURCE[0]}")/connect.sh"

echo "applying the model to ${DB_NAME} on ${INSTANCE_CONNECTION_NAME} as ${DB_USER}"

if [ "$WITH_ROLES" = "1" ]; then
  /model/migrate.sh -d "$DB_NAME" --with-roles
else
  /model/migrate.sh -d "$DB_NAME"
fi

# Connecting Cloud SQL's IAM users to the roles the model just created.
#
# Not in model.list - it names Google service accounts and means nothing on a container -
# so it is applied here, once, by whoever can grant roles. On dev this was a job of its
# own and a new instance had no equivalent, which is how staging would have come up with
# a model and no way for anything to connect to it.
#
# Every statement in it is guarded, so a later run by the migration login, which has no
# CREATEROLE, does nothing rather than failing.
if [ -n "${GCP_PROJECT:-}" ] && [ -n "${GCP_ENV:-}" ]; then
  echo "granting the IAM database users their roles"
  psql -v ON_ERROR_STOP=1 \
    -c "SET dailycare.project = '${GCP_PROJECT}'; SET dailycare.env = '${GCP_ENV}';" \
    -f /model/cloudsql-iam.sql
fi

echo
echo "what is in the database now:"
psql -c "SELECT position, filename, left(sha256, 12) AS sha, applied_by
         FROM schema_migrations ORDER BY position"
