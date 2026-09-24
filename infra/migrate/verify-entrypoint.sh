#!/usr/bin/env bash
#
# The suites, against whatever database this job is pointed at.
#
# It calls verify.sh rather than reimplementing it. The first version of this file ran all
# fourteen suites against one database and drowned in duplicate-key errors, which is the
# thing verify.sh exists to avoid and says so in its own comments: every suite seeds the
# same fixtures and then tries to violate them, so each needs a database of its own.
# Writing a second runner was the mistake; there is one runner.
#
# What this adds over running it in a container is the only thing worth adding: the
# instance is a managed one. Nobody gets a superuser there, and a superuser bypasses every
# policy under test - which has already made 193 checks pass here for the wrong reason once.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/connect.sh"
until psql -d postgres -c 'SELECT 1' >/dev/null 2>&1; do sleep 2; done

echo "connected to ${INSTANCE_CONNECTION_NAME} as $(psql -At -d postgres -c 'SELECT current_user')"
psql -At -d postgres -c "SELECT 'superuser: ' || coalesce(rolsuper::text,'?') FROM pg_roles WHERE rolname = current_user"
echo
cd /model && ./verify.sh
