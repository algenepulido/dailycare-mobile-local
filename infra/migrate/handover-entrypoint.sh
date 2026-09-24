#!/usr/bin/env bash
#
# Handing the schema to dailycare_owner. Once per instance, as postgres.
#
# The only ownership statement that is not in the model, and it is here rather than there
# for a reason: a model file that needed to own the schema would refuse to apply on every
# database where it did not, which is every database until somebody had already done this.
#
# ORDER. Run this only once the jobs already connect as the migration login. DROP SCHEMA
# needs the schema's owner, so after this the reset job - which is that login, defaulting
# to dailycare_owner - drops the postgres-owned tables along with the schema and rebuilds
# everything owned correctly. Run it the other way round and the next reset puts every
# table back on postgres, which is what happened on this instance on 23 September between
# 21:45 and 22:08.
#
# Nothing else from the review's bootstrap is needed. The object-by-object loops exist to
# catch up a database postgres built; once the schema itself has moved, the first reset
# renews the rest through the ordinary loop.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/connect.sh"

echo "── before"
psql -c "SELECT pg_get_userbyid(nspowner) AS schema_owner FROM pg_namespace WHERE nspname='public'"
psql -c "SELECT pg_get_userbyid(relowner) AS owner, count(*) AS objects
         FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
         WHERE n.nspname='public' AND c.relkind IN ('r','v','S') GROUP BY 1 ORDER BY 2 DESC"

# postgres has to be a member of the role it hands an object to. Left in place afterwards:
# postgres is cloudsqlsuperuser and can grant itself back in one statement, so removing it
# would buy nothing and a break-glass session would have no way to fix a mistake here.
psql -v ON_ERROR_STOP=1 -c "GRANT dailycare_owner TO postgres"

# CREATE on the database, so the owner can recreate the schema a reset drops.
psql -v ON_ERROR_STOP=1 -c "GRANT CREATE ON DATABASE ${DB_NAME} TO dailycare_owner"
psql -v ON_ERROR_STOP=1 -c "ALTER SCHEMA public OWNER TO dailycare_owner"

echo "── after"
psql -c "SELECT pg_get_userbyid(nspowner) AS schema_owner FROM pg_namespace WHERE nspname='public'"
echo ""
echo "The objects are still owned by postgres and that is expected. The next reset, run by"
echo "the migration login, drops them with the schema and rebuilds them as dailycare_owner."
