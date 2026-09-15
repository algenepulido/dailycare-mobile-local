-- Access control checks for access-policies.sql
--
-- Written as attempts to get at something that should not be reachable, because a policy
-- that has only ever been tested by the person it is meant to admit has not been tested.
--
--   createdb dc_access_check
--   psql -v ON_ERROR_STOP=1 -d dc_access_check -f schema.sql
--   psql -v ON_ERROR_STOP=1 -d dc_access_check -f access-policies.sql
--   psql -d dc_access_check -f access-invariants.sql
--   dropdb dc_access_check
--
-- The checks run as a non-superuser role, because a superuser bypasses row-level security
-- entirely and would report that everything works.

\set QUIET on
SET client_min_messages TO notice;
-- Lift FORCE for this suite so that it behaves the same run by a superuser and run by a
-- managed-instance owner. See checks-support.sql: the policies stay in force, and every
-- check that tests one does it by becoming the role it is about.
SELECT checks_begin();

-- The role the application will connect as. Ordinary privileges, no BYPASSRLS.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dailycare_app') THEN
    RAISE EXCEPTION 'role dailycare_app does not exist. Apply roles.sql first.';
  END IF;
END $$;

GRANT USAGE ON SCHEMA public TO dailycare_app;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO dailycare_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO dailycare_app;

CREATE OR REPLACE FUNCTION expect_rows(label text, expected int, q text) RETURNS void AS $$
DECLARE actual int;
BEGIN
  EXECUTE 'SELECT count(*) FROM (' || q || ') t' INTO actual;
  IF actual = expected THEN
    RAISE NOTICE 'PASS  % — sees % row(s)', label, actual;
  ELSE
    RAISE NOTICE 'FAIL  % — expected %, saw %', label, expected, actual;
  END IF;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION expect_refused(label text, stmt text) RETURNS void AS $$
BEGIN
  BEGIN
    EXECUTE stmt;
  EXCEPTION WHEN insufficient_privilege OR check_violation THEN
    RAISE NOTICE 'PASS  refused: %', label;
    RETURN;
  END;
  RAISE NOTICE 'FAIL  ALLOWED, and should not have been: %', label;
END; $$ LANGUAGE plpgsql;
\set QUIET off


-- ── fixtures, seeded as the owner so row-level security does not hide them ──────
-- Two facilities. Cedar has two residents; Birch has one, and exists purely so that
-- "another facility" is a real place rather than a hypothetical.

INSERT INTO facilities (id, name, timezone) VALUES
  ('f1000000-0000-0000-0000-000000000001', 'Cedar House', 'America/Chicago'),
  ('f2000000-0000-0000-0000-000000000002', 'Birch House', 'America/Chicago');

INSERT INTO users (id, email, display_name) VALUES
  ('a0000000-0000-0000-0000-00000000000a', 'maria@example.test',   'Maria'),    -- caregiver, Cedar
  ('b0000000-0000-0000-0000-00000000000b', 'manager@example.test', 'Priya'),    -- care manager, Cedar
  ('c0000000-0000-0000-0000-00000000000c', 'anna@example.test',    'Anna'),     -- daughter of Cathy
  ('d0000000-0000-0000-0000-00000000000d', 'ben@example.test',     'Ben');      -- caregiver, Birch

INSERT INTO facility_members (id, facility_id, user_id, role, state) VALUES
  ('fa000000-0000-0000-0000-00000000000a', 'f1000000-0000-0000-0000-000000000001',
   'a0000000-0000-0000-0000-00000000000a', 'caregiver',    'active'),
  ('fb000000-0000-0000-0000-00000000000b', 'f1000000-0000-0000-0000-000000000001',
   'b0000000-0000-0000-0000-00000000000b', 'care_manager', 'active'),
  ('fd000000-0000-0000-0000-00000000000d', 'f2000000-0000-0000-0000-000000000002',
   'd0000000-0000-0000-0000-00000000000d', 'caregiver',    'active');

INSERT INTO residents (id, facility_id, display_name) VALUES
  ('e1000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000001', 'Cathy'),
  ('e2000000-0000-0000-0000-000000000002', 'f1000000-0000-0000-0000-000000000001', 'Robert'),
  ('e3000000-0000-0000-0000-000000000003', 'f2000000-0000-0000-0000-000000000002', 'Mabel');

-- Maria is assigned to Cathy only. Robert is in the same building and not hers.
INSERT INTO assignments (facility_id, resident_id, facility_member_id) VALUES
  ('f1000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001',
   'fa000000-0000-0000-0000-00000000000a');

INSERT INTO resident_contacts (facility_id, resident_id, user_id, relation, state, granted_at) VALUES
  ('f1000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001',
   'c0000000-0000-0000-0000-00000000000c', 'child', 'active', now());

INSERT INTO care_days (id, facility_id, resident_id, care_date, mood, appetite, sleep, filed_by) VALUES
  ('cd000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000001',
   'e1000000-0000-0000-0000-000000000001', '2026-09-14', 'calm', 'fair', 'restless',
   'a0000000-0000-0000-0000-00000000000a'),
  ('cd000000-0000-0000-0000-000000000002', 'f1000000-0000-0000-0000-000000000001',
   'e2000000-0000-0000-0000-000000000002', '2026-09-14', 'calm', 'good', 'slept_well',
   'a0000000-0000-0000-0000-00000000000a');

-- One meal and one concern on Cathy's day, so that the checks about what cannot be deleted
-- have something to fail to delete.
INSERT INTO care_day_meals (care_day_id, slot, happened, amount) VALUES
  ('cd000000-0000-0000-0000-000000000001', 'breakfast', true, 'half');
INSERT INTO care_day_concerns (care_day_id, concern) VALUES
  ('cd000000-0000-0000-0000-000000000001', 'sundowning');

SET ROLE dailycare_app;


-- ── nobody ─────────────────────────────────────────────────────────────────────

\echo ''
\echo '── a request that never said who it is'
SELECT set_config('app.user_id', '', false);
SELECT expect_rows('unidentified request, residents', 0, 'SELECT * FROM residents');
SELECT expect_rows('unidentified request, care days', 0, 'SELECT * FROM care_days');


-- ── the caregiver ──────────────────────────────────────────────────────────────

\echo ''
\echo '── Maria, caregiver at Cedar, assigned to Cathy only'
SELECT set_config('app.user_id', 'a0000000-0000-0000-0000-00000000000a', false);

SELECT expect_rows('her own resident', 1,
  $$SELECT * FROM residents WHERE id = 'e1000000-0000-0000-0000-000000000001'$$);
SELECT expect_rows('Robert, same building, not assigned to her', 0,
  $$SELECT * FROM residents WHERE id = 'e2000000-0000-0000-0000-000000000002'$$);
SELECT expect_rows('Mabel, a different facility entirely', 0,
  $$SELECT * FROM residents WHERE id = 'e3000000-0000-0000-0000-000000000003'$$);
SELECT expect_rows('every resident she can reach', 1, 'SELECT * FROM residents');
SELECT expect_rows('care days she can reach', 1, 'SELECT * FROM care_days');

SELECT expect_refused('filing a care day for a resident she is not assigned to', $$
  INSERT INTO care_days (facility_id, resident_id, care_date, mood, appetite, sleep, filed_by)
  VALUES ('f1000000-0000-0000-0000-000000000001', 'e2000000-0000-0000-0000-000000000002',
          '2026-09-15', 'calm', 'good', 'slept_well', 'a0000000-0000-0000-0000-00000000000a')
$$);

SELECT expect_refused('admitting a resident, which is a manager''s job', $$
  INSERT INTO residents (facility_id, display_name)
  VALUES ('f1000000-0000-0000-0000-000000000001', 'Someone New')
$$);

SELECT expect_refused('forging a medication event attributed to the clinical system', $$
  INSERT INTO medication_events (facility_id, resident_id, care_date, slot, status, source, source_ref)
  VALUES ('f1000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001',
          '2026-09-14', 'am', 'given', 'pointclickcare', 'PCC-FAKE-1')
$$);

SELECT expect_refused('granting a family member access, which is a manager''s job', $$
  INSERT INTO resident_contacts (facility_id, resident_id, user_id, relation, state)
  VALUES ('f1000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001',
          'd0000000-0000-0000-0000-00000000000d', 'friend', 'active')
$$);


-- ── the care manager ───────────────────────────────────────────────────────────

\echo ''
\echo '── Priya, care manager at Cedar'
SELECT set_config('app.user_id', 'b0000000-0000-0000-0000-00000000000b', false);

SELECT expect_rows('every resident in her building', 2, 'SELECT * FROM residents');
SELECT expect_rows('and nobody in Birch', 0,
  $$SELECT * FROM residents WHERE facility_id = 'f2000000-0000-0000-0000-000000000002'$$);
SELECT expect_rows('every care day in her building', 2, 'SELECT * FROM care_days');


-- ── the family member ──────────────────────────────────────────────────────────

\echo ''
\echo '── Anna, Cathy''s daughter'
SELECT set_config('app.user_id', 'c0000000-0000-0000-0000-00000000000c', false);

SELECT expect_rows('her mother', 1, 'SELECT * FROM residents');
SELECT expect_rows('her mother''s days', 1, 'SELECT * FROM care_days');
SELECT expect_rows('Robert, who is not hers', 0,
  $$SELECT * FROM care_days WHERE resident_id = 'e2000000-0000-0000-0000-000000000002'$$);

SELECT expect_refused('filing a care day — family receive care, they do not record it', $$
  INSERT INTO care_days (facility_id, resident_id, care_date, mood, appetite, sleep, filed_by)
  VALUES ('f1000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001',
          '2026-09-16', 'calm', 'good', 'slept_well', 'c0000000-0000-0000-0000-00000000000c')
$$);

SELECT expect_refused('recording a medication event', $$
  INSERT INTO medication_events (facility_id, resident_id, care_date, slot, status, source, recorded_by)
  VALUES ('f1000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001',
          '2026-09-16', 'am', 'given', 'caregiver', 'c0000000-0000-0000-0000-00000000000c')
$$);

SELECT expect_rows('her own grant, so the app can list who she is linked to', 1,
  'SELECT * FROM resident_contacts');


-- ── access that has been taken away ────────────────────────────────────────────

\echo ''
-- ── nothing deletes ────────────────────────────────────────────────────────────
--
-- These exist because the previous version of this file proved the wrong thing. It tried
-- to delete a resident as the application, saw nothing removed, and passed - while
-- app.user_id was unset, so the row was hidden rather than protected. The care manager
-- below is identified and is the one person who would be expected to get away with it.

\echo ''
\echo '── what the application may destroy, which is nothing'

SET ROLE dailycare_app;
SELECT set_config('app.user_id', 'b0000000-0000-0000-0000-00000000000b', false) \gset

SELECT expect_rows('an identified care manager sees her residents, so she is really a manager', 2,
  'SELECT * FROM residents');

-- Table-level DELETE is granted for this section on purpose. In production it is not
-- granted at all, and the point of these checks is that the policies would stop the
-- deletes even if it were - so that the guarantee does not rest on one GRANT nobody
-- reviews again.
RESET ROLE;
\set QUIET on
GRANT DELETE ON residents, resident_contacts, care_days, care_day_meals,
  care_day_concerns, medication_events, media_objects TO dailycare_app;
\set QUIET off
SET ROLE dailycare_app;
SELECT set_config('app.user_id', 'b0000000-0000-0000-0000-00000000000b', false) \gset

\set QUIET on
DELETE FROM residents         WHERE id = 'e1000000-0000-0000-0000-000000000001';
DELETE FROM resident_contacts WHERE resident_id = 'e1000000-0000-0000-0000-000000000001';
DELETE FROM care_days         WHERE id = 'cd000000-0000-0000-0000-000000000001';
DELETE FROM medication_events WHERE resident_id = 'e1000000-0000-0000-0000-000000000001';
DELETE FROM media_objects     WHERE resident_id = 'e1000000-0000-0000-0000-000000000001';
\set QUIET off

SELECT expect_rows('and she still cannot remove one', 2, 'SELECT * FROM residents');
SELECT expect_rows('nor withdraw access by deleting the grant', 1,
  'SELECT * FROM resident_contacts');
SELECT expect_rows('nor remove a care day', 2, 'SELECT * FROM care_days');

SET ROLE dailycare_app;
SELECT set_config('app.user_id', 'a0000000-0000-0000-0000-00000000000a', false) \gset
\set QUIET on
DELETE FROM care_day_meals    WHERE care_day_id = 'cd000000-0000-0000-0000-000000000001';
DELETE FROM care_day_concerns WHERE care_day_id = 'cd000000-0000-0000-0000-000000000001';
\set QUIET off
RESET ROLE;

SELECT expect_rows('nor a caregiver a meal she filed', 1,
  $$SELECT * FROM care_day_meals WHERE care_day_id = 'cd000000-0000-0000-0000-000000000001'$$);
SELECT expect_rows('nor a concern', 1,
  $$SELECT * FROM care_day_concerns WHERE care_day_id = 'cd000000-0000-0000-0000-000000000001'$$);

-- And the structural version of the same statement, which does not depend on anybody
-- having thought to try the right delete.
SELECT expect_rows('no policy in the access model permits an application role to delete', 0,
  $$SELECT * FROM pg_policies
    WHERE schemaname = 'public' AND cmd IN ('DELETE','ALL')
      AND NOT (roles::text LIKE '%dailycare_retention%')$$);


-- ── the matrix and the database agree ──────────────────────────────────────────

\echo ''
\echo '── the access matrix against the catalogue it describes'

SELECT expect_rows('every actor has an answer for every table and every operation', 0,
  'SELECT * FROM access_matrix_blanks');

SELECT expect_rows('and the matrix is not empty, which would make that cheap',
  192, 'SELECT * FROM access_matrix');

SELECT expect_rows('no table permits a delete the matrix says nothing can be deleted from', 0,
  'SELECT * FROM access_matrix_delete_drift');

SELECT expect_rows('no PHI-bearing table is missing from the matrix', 0,
  'SELECT * FROM access_matrix_uncovered_tables');

\echo ''
\echo '── the matrix as the reviewer reads it'
SELECT table_name, operation, caregiver, care_manager, family FROM access_matrix_report
WHERE table_name IN ('residents','care_days','media_objects') ORDER BY table_name, operation;


\echo '── after access is withdrawn and after a shift ends'
RESET ROLE;
UPDATE resident_contacts SET state = 'revoked', revoked_at = now()
WHERE user_id = 'c0000000-0000-0000-0000-00000000000c';
SET ROLE dailycare_app;

SELECT set_config('app.user_id', 'c0000000-0000-0000-0000-00000000000c', false);
SELECT expect_rows('a revoked family member', 0, 'SELECT * FROM residents');
SELECT expect_rows('and their care days', 0, 'SELECT * FROM care_days');

RESET ROLE;
UPDATE assignments SET ended_at = now()
WHERE facility_member_id = 'fa000000-0000-0000-0000-00000000000a';
SET ROLE dailycare_app;

SELECT set_config('app.user_id', 'a0000000-0000-0000-0000-00000000000a', false);
SELECT expect_rows('a caregiver whose assignment has ended', 0, 'SELECT * FROM residents');

RESET ROLE;
UPDATE facility_members SET state = 'revoked', ended_at = now()
WHERE id = 'fb000000-0000-0000-0000-00000000000b';
SET ROLE dailycare_app;

SELECT set_config('app.user_id', 'b0000000-0000-0000-0000-00000000000b', false);
SELECT expect_rows('a deactivated care manager', 0, 'SELECT * FROM residents');

\echo ''
RESET ROLE;
SELECT checks_end();
DROP FUNCTION expect_rows(text, int, text);
DROP FUNCTION expect_refused(text, text);
