#!/usr/bin/env bash
#
# What is actually on the instance.
#
# Read-only. Every question here is one that was answered by reasoning at some point and
# turned out to need looking at instead: the seed's row-security drift was invisible for a
# day because nothing ever asked the deployed database what it thought.
set -euo pipefail
export PGHOST="/cloudsql/${INSTANCE_CONNECTION_NAME}" PGUSER="$DB_USER" PGDATABASE="$DB_NAME"
until psql -c 'SELECT 1' >/dev/null 2>&1; do sleep 2; done

echo "── who is here"
psql -c "SELECT email, display_name, password_hash IS NOT NULL AS has_password,
                deactivated_at IS NULL AS active FROM users ORDER BY email"
psql -c "SELECT count(*) AS residents FROM residents"
psql -c "SELECT count(*) AS assignments, count(assigned_by) AS with_an_author FROM assignments"

echo "── row security: forced on exactly what the model declares?"
psql -c "SELECT * FROM row_security_drift"

echo "── what the model has that the application can call"
psql -c "SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public' AND proname IN
           ('redeem_token','consume_token','credential_for_sign_in','start_session')
         ORDER BY 1"

echo "── invitations outstanding"
psql -c "SELECT purpose, count(*) FILTER (WHERE consumed_at IS NULL) AS unused,
                count(*) FILTER (WHERE consumed_at IS NOT NULL) AS used
         FROM user_tokens GROUP BY purpose ORDER BY 1"

echo "── roles, and who owns the schema"
psql -c "SELECT rolname, rolcanlogin AS can_login, rolbypassrls AS bypasses_rls, rolsuper
         FROM pg_roles WHERE rolname LIKE 'dailycare%' OR rolname = 'postgres' ORDER BY 1"
psql -c "SELECT nspname AS schema, pg_get_userbyid(nspowner) AS owner
         FROM pg_namespace WHERE nspname = 'public'"
psql -c "SELECT pg_get_userbyid(relowner) AS owner, count(*) AS tables
         FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public' AND c.relkind = 'r'
         GROUP BY 1 ORDER BY 2 DESC"

echo "── anything the model does not declare"
psql -c "SELECT rolname FROM pg_roles
         WHERE rolname LIKE 'dailycare%'
           AND rolname NOT IN ('dailycare_app','dailycare_retention',
                               'dailycare_integration','dailycare_backup')"

echo "── migrations applied"
psql -c "SELECT count(*) AS files, max(applied_at) AS most_recent FROM schema_migrations"
