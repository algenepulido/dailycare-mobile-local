#!/usr/bin/env bash
#
# How every job in this directory reaches the database.
#
# One file rather than the same four lines in six entrypoints, because the thing that
# changes here is which credential is in play and that has to change in one place.
#
# Two ways, and which one is used is decided by whether a password was handed in rather
# than by a flag. PGPASSWORD set means the old path: the built-in administrator and a
# secret. Nothing set means the new one: the job proves who it is with the identity it
# runs as, and Cloud SQL's IAM authentication takes a short-lived OAuth token where the
# password would go. There is no password to store, rotate, or leave in a secret nobody
# remembers creating.
#
# The old path stays until the postgres credential is retired, deliberately. A cutover
# that removes the way back before the new way has run is a cutover nobody can undo.

set -euo pipefail

export PGHOST="/cloudsql/${INSTANCE_CONNECTION_NAME}"
export PGUSER="${DB_USER}"
export PGDATABASE="${DB_NAME}"

if [ -z "${PGPASSWORD:-}" ]; then
  # The scope matters. Cloud SQL checks the token was minted for sqlservice.login, and a
  # token for anything else is refused at connect with a message about the password -
  # which reads like a wrong secret rather than a wrong scope.
  token="$(curl -sf -H 'Metadata-Flavor: Google' \
    "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token?scopes=https://www.googleapis.com/auth/sqlservice.login" \
    | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')"

  if [ -z "$token" ]; then
    echo "could not get an access token from the metadata server." >&2
    echo "This job authenticates as the service account it runs as; there is no password" >&2
    echo "to fall back to. Check the job's service account and that the instance has" >&2
    echo "cloudsql.iam_authentication on." >&2
    exit 1
  fi

  export PGPASSWORD="$token"
  echo "connecting as $PGUSER with a token, not a password"
else
  echo "connecting as $PGUSER with a password"
fi

# Waiting here rather than in six places. The socket appears when the runtime has the
# Cloud SQL connection up, which is not the moment the container starts.
until psql -c 'SELECT 1' >/dev/null 2>&1; do sleep 2; done
