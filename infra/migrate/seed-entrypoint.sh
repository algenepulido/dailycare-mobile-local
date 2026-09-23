#!/usr/bin/env bash
set -euo pipefail
export PGHOST="/cloudsql/${INSTANCE_CONNECTION_NAME}" PGUSER="$DB_USER" PGDATABASE="$DB_NAME"
until psql -c 'SELECT 1' >/dev/null 2>&1; do sleep 2; done
# FORCE row-level security applies to the table owner too, which is the point of it - and
# on Cloud SQL the postgres user is not a superuser, so it is subject to the policies like
# anybody else. Seeding is not something the policies have a story for: there is no session
# identity because the rows being written are what an identity would be checked against.
#
# So the force is lifted for the insert and put back. checks-support.sql does the same
# thing for the suites and for the same reason.
psql -v ON_ERROR_STOP=1 -v h="$SEED_HASH" <<'SQL'
-- residents only. assignments is ENABLE and not FORCE in the model, so the owner is
-- already outside its policies and lifting it achieves nothing - but turning it back ON,
-- which is what this used to do, left a seeded database with an access model the model
-- never declared. Restore what was there, never assert a value; checks-support.sql and
-- the scrub in environments.sql both do it by reading first, and row_security_drift now
-- fails the build if anything gets this wrong again.
ALTER TABLE residents NO FORCE ROW LEVEL SECURITY;
INSERT INTO facilities (id, name, timezone) VALUES
 ('11111111-1111-1111-1111-111111111111','Cedar House','America/Chicago')
ON CONFLICT (id) DO NOTHING;
INSERT INTO users (id, email, display_name, password_hash) VALUES
 ('22222222-2222-2222-2222-222222222222','nurse@cedar.test','Maria Santos', :'h')
ON CONFLICT (id) DO UPDATE SET password_hash = excluded.password_hash;
-- On the natural key rather than the primary one. A membership is unique per facility,
-- user and role, so a second run with a fresh uuid collides on that instead - which is
-- what happened, and is the constraint being right about what a duplicate is.
INSERT INTO facility_members (id, facility_id, user_id, role, state) VALUES
 ('33333333-3333-3333-3333-333333333333','11111111-1111-1111-1111-111111111111',
  '22222222-2222-2222-2222-222222222222','caregiver','active')
ON CONFLICT (facility_id, user_id, role) DO NOTHING;
INSERT INTO residents (id, facility_id, display_name) VALUES
 ('44444444-4444-4444-4444-444444444444','11111111-1111-1111-1111-111111111111','Cathy')
ON CONFLICT (id) DO NOTHING;
-- The membership this refers to, whichever uuid it has. ON CONFLICT DO NOTHING above
-- keeps whatever row is already there, so a second run with a fresh id leaves the new one
-- unwritten and a hardcoded reference to it points at nothing.
INSERT INTO assignments (facility_id, resident_id, facility_member_id)
SELECT '11111111-1111-1111-1111-111111111111',
       '44444444-4444-4444-4444-444444444444',
       fm.id
  FROM facility_members fm
 WHERE fm.facility_id = '11111111-1111-1111-1111-111111111111'
   AND fm.user_id     = '22222222-2222-2222-2222-222222222222'
   AND fm.role        = 'caregiver'
ON CONFLICT DO NOTHING;
ALTER TABLE residents FORCE ROW LEVEL SECURITY;

SELECT 'seeded: ' || (SELECT count(*) FROM residents) || ' residents, '
       || (SELECT count(*) FROM users) || ' users, '
       || (SELECT count(*) FROM assignments) || ' assignments';
SQL
