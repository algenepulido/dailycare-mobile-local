#!/usr/bin/env bash
#
# What is actually on the instance.
#
# Read-only. Every question here is one that was answered by reasoning at some point and
# turned out to need looking at instead: the seed's row-security drift was invisible for a
# day because nothing ever asked the deployed database what it thought.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/connect.sh"

echo "── who is here"
psql -c "SELECT email, display_name, password_hash IS NOT NULL AS has_password,
                deactivated_at IS NULL AS active FROM users ORDER BY email"
# The buildings themselves, by name and by id.
#
# This asked who is here and how many residents there are and could not say which building
# any of it was in - so anybody wanting to put somebody into one had to go and find the uuid
# somewhere else, which is the sort of thing this job exists to stop.
psql -c "SELECT f.id, f.name,
                EXISTS (SELECT 1 FROM facility_agreements a
                         WHERE a.facility_id = f.id AND a.executed_on <= current_date
                           AND a.terminated_on IS NULL) AS covered
           FROM facilities f ORDER BY f.name"
psql -c "SELECT f.name AS facility, u.display_name, fm.role, fm.state,
                fm.ended_at IS NULL AS open
           FROM facility_members fm
           JOIN users u ON u.id = fm.user_id
           JOIN facilities f ON f.id = fm.facility_id
          ORDER BY f.name, fm.role, u.display_name"
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
                               'dailycare_integration','dailycare_backup',
                               'dailycare_owner')"

echo "── and the two that decide whether a reset renews ownership or undoes it"
psql -c "SELECT r.rolname AS login, s.setconfig AS starts_every_session_with
         FROM pg_db_role_setting s JOIN pg_roles r ON r.oid = s.setrole
         WHERE r.rolname LIKE '%migrate%'"
psql -c "SELECT rolname, rolcreatedb FROM pg_roles WHERE rolname = 'dailycare_owner'"

echo "── migrations applied"
psql -c "SELECT count(*) AS files, max(applied_at) AS most_recent FROM schema_migrations"

echo "── the audit trail, most recent first"
# Readable from here because dc-<env>-migrate connects as dailycare_owner, which inherits
# dailycare_retention, whose policy on audit_events is USING (true). Measured rather than
# assumed: with the table forced, dailycare_owner sees every row and dailycare_app sees
# none. That the migration identity can read the whole trail is a consequence of the role
# grant rather than a decision anybody made, and it is written down in the deferred list.
psql -c "SELECT to_char(occurred_at, 'Mon DD HH24:MI:SS') AS at, action, actor_role,
                left(coalesce(actor_user_id::text, 'none'), 8) AS actor
         FROM audit_events ORDER BY occurred_at DESC LIMIT 12"
psql -c "SELECT count(*) AS rows_in_the_trail FROM audit_events"
