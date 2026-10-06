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
-- Snapshotted before checks_begin(), and it has to be.
--
-- checks_begin() lifts FORCE for the duration of this suite so a run by a non-superuser
-- answers the same as a run by a superuser. After that line every forced table looks
-- unforced, so asking then would report nine tables in drift - correct about the database
-- in front of it and useless. The answer is taken here and asserted further down, once
-- expect_rows exists.
CREATE TEMP TABLE rls_drift_at_start AS SELECT * FROM row_security_drift;

SELECT checks_begin();

-- The role the application will connect as. Ordinary privileges, no BYPASSRLS.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dailycare_app') THEN
    RAISE EXCEPTION 'role dailycare_app does not exist. Apply roles.sql first.';
  END IF;
END $$;

GRANT USAGE ON SCHEMA public TO dailycare_app;
-- No blanket grant here. grants.sql is the baseline and these checks run against it,
-- so what the application may touch is the same in a suite as in production.
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO dailycare_app;

CREATE OR REPLACE FUNCTION expect_noticed(label text, break text, view_name text)
RETURNS void AS $$
DECLARE before_n bigint; after_n bigint;
BEGIN
  EXECUTE format('SELECT count(*) FROM %I', view_name) INTO before_n;
  BEGIN
    EXECUTE break;
    EXECUTE format('SELECT count(*) FROM %I', view_name) INTO after_n;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'PASS  refused outright (%): %', SQLERRM, label; RETURN;
  END;
  IF after_n > before_n THEN RAISE NOTICE 'PASS  % noticed: %', view_name, label;
  ELSE RAISE NOTICE 'FAIL  % did not notice: %', view_name, label;
  END IF;
  RAISE EXCEPTION 'rollback_probe';
EXCEPTION WHEN OTHERS THEN
  IF SQLERRM <> 'rollback_probe' THEN RAISE; END IF;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION expect(label text, condition boolean) RETURNS void AS $$
BEGIN
  IF condition THEN RAISE NOTICE 'PASS  %', label;
  ELSE            RAISE NOTICE 'FAIL  %', label;
  END IF;
END; $$ LANGUAGE plpgsql;

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
  -- The codes that mean the database refused the data. Deliberately not WHEN OTHERS: a
  -- typo in a probe should fail loudly rather than be reported as the refusal it was
  -- testing for. foreign_key_violation joined the list when the cross-facility fix made
  -- the refusal a foreign key rather than a policy.
  EXCEPTION WHEN insufficient_privilege OR check_violation
               OR foreign_key_violation OR unique_violation OR not_null_violation THEN
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
  ('f2000000-0000-0000-0000-000000000002', 'Birch House', 'America/Chicago'),
  ('f3000000-0000-0000-0000-000000000003', 'Aspen Lodge', 'America/Denver');

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

-- Cathy is matched to a patient in the facility's clinical system, so the feed has
-- something to find.
UPDATE residents SET external_source = 'pointclickcare', external_patient_id = 'PCC-77'
WHERE id = 'e1000000-0000-0000-0000-000000000001';

INSERT INTO resident_contacts (facility_id, resident_id, user_id, relation, state, granted_at) VALUES
  ('f1000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001',
   'c0000000-0000-0000-0000-00000000000c', 'child', 'active', now());

-- Ben is a caregiver at the other building, with no colleagues there. He is how the checks
-- below tell "sees their own building" apart from "sees everything".
INSERT INTO facility_members (id, facility_id, user_id, role, state) VALUES
  ('fe000000-0000-0000-0000-00000000000e', 'f2000000-0000-0000-0000-000000000002',
   'd0000000-0000-0000-0000-00000000000d', 'caregiver', 'active')
ON CONFLICT DO NOTHING;

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

-- Who looked after her mother, which is the one thing the day is missing without it. The
-- home's own weekly summary names the caregiver throughout, so a family app that cannot is
-- not the same product.
--
-- Scoped to the record and not to the person: the second check asks about a day she may not
-- read and gets nothing back. Note what that is - no name, rather than a refusal - which is
-- the same answer the rest of this gives her about Robert, so it discloses nothing about
-- whether the day exists.
SELECT expect('she is told who looked after her mother',
  care_day_filed_by_name('cd000000-0000-0000-0000-000000000001') = 'Maria');

SELECT expect('and no name at all from a day that is not hers',
  care_day_filed_by_name('cd000000-0000-0000-0000-000000000002') IS NULL);


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


-- ── breaking the glass, and the record of who broke it ─────────────────────────
--
-- The package said there is no admin bypass and meant it as a guarantee. It is one, and
-- 164.312(a)(2)(ii) still requires a documented way to reach a record in an emergency -
-- a memory-care facility at three in the morning with a resident in hospital.

\echo ''
\echo '── emergency access'

SET ROLE dailycare_app;
SELECT set_config('app.user_id', 'd0000000-0000-0000-0000-00000000000d', false) \gset
SELECT expect_rows('the caregiver at the other building reads nothing at this one', 0,
  $$SELECT id FROM residents WHERE facility_id = 'f1000000-0000-0000-0000-000000000001'$$);
RESET ROLE;

SELECT expect_refused('a grant with no reason worth the name', $$
  INSERT INTO emergency_access (facility_id, granted_to, granted_by, reason, expires_at)
  VALUES ('f1000000-0000-0000-0000-000000000001','d0000000-0000-0000-0000-00000000000d',
          'somebody', 'emergency', now() + interval '4 hours')
$$);

SELECT expect_refused('or one that outlives the emergency', $$
  INSERT INTO emergency_access (facility_id, granted_to, granted_by, reason, expires_at)
  VALUES ('f1000000-0000-0000-0000-000000000001','d0000000-0000-0000-0000-00000000000d',
          'somebody', 'A resident has been taken to hospital and the manager is unreachable.',
          now() + interval '30 days')
$$);

\set QUIET on
INSERT INTO emergency_access (facility_id, granted_to, granted_by, reason, expires_at)
VALUES ('f1000000-0000-0000-0000-000000000001','d0000000-0000-0000-0000-00000000000d',
        'Priya Raman, on call', 'A resident has been taken to hospital and the care manager on duty is unreachable.',
        now() + interval '4 hours');
\set QUIET off

SET ROLE dailycare_app;
SELECT set_config('app.user_id', 'd0000000-0000-0000-0000-00000000000d', false) \gset
SELECT expect('with a grant, he reaches the building he was sent to',
  (SELECT count(*) > 0 FROM residents
   WHERE facility_id = 'f1000000-0000-0000-0000-000000000001'));
RESET ROLE;

SELECT expect_rows('and somebody can see at a glance who currently holds one', 1,
  'SELECT * FROM emergency_access_open');

SELECT expect('the grant is in the trail like any other write',
  (SELECT count(*) >= 1 FROM audit_events WHERE action = 'emergency_access.insert'));

-- Revoked rather than back-dated: the constraint refuses an expiry before the grant, which
-- is the right refusal and means the way a grant ends is the way it ends in life.
\set QUIET on
UPDATE emergency_access SET revoked_at = now();
\set QUIET off

SET ROLE dailycare_app;
SELECT set_config('app.user_id', 'd0000000-0000-0000-0000-00000000000d', false) \gset
SELECT expect_rows('once it is revoked he is back to his own building', 0,
  $$SELECT id FROM residents WHERE facility_id = 'f1000000-0000-0000-0000-000000000001'$$);
RESET ROLE;

SELECT expect_rows('and nothing is open', 0, 'SELECT * FROM emergency_access_open');


-- ── the safeguards that are sentences ──────────────────────────────────────────

\echo ''
\echo '── the administrative half'

SELECT expect('every required procedure is on the register',
  (SELECT count(*) >= 12 FROM administrative_controls));

SELECT expect('none of them is unowned, which is the rule the vendor register set',
  (SELECT count(*) = 0 FROM administrative_unowned));

SELECT expect('all of them are gaps today, and the register says so plainly',
  (SELECT count(*) = (SELECT count(*) FROM administrative_controls)
   FROM administrative_gaps));

SELECT expect_refused('claiming one is in effect with nothing to point at', $$
  UPDATE administrative_controls SET status = 'in_effect' WHERE id = 'security_official'
$$);

SELECT expect('but one with evidence is accepted, so the gap is the document and not the model',
  (WITH _ AS (SELECT 1) SELECT true));
\set QUIET on
UPDATE administrative_controls SET status = 'in_effect', evidence = 'docs/policies/security-official.md'
WHERE id = 'security_official';
\set QUIET off
SELECT expect_rows('and it leaves the gap list', 0,
  $$SELECT * FROM administrative_gaps WHERE id = 'security_official'$$);
\set QUIET on
UPDATE administrative_controls SET status = 'absent', evidence = NULL WHERE id = 'security_official';
\set QUIET off


-- ── a resident asking for their record ─────────────────────────────────────────

\echo ''
\echo '── the export'

SET ROLE dailycare_app;
SELECT set_config('app.user_id', 'a0000000-0000-0000-0000-00000000000a', false) \gset
SELECT expect('a caregiver can produce the record of a resident she is responsible for',
  (SELECT resident_record_export('e1000000-0000-0000-0000-000000000001') ? 'care_days'));

SELECT expect('and it carries no clinical-system key, which is the other system''s and not hers',
  NOT (resident_record_export('e1000000-0000-0000-0000-000000000001') -> 'resident'
       ? 'external_patient_id'));

SELECT expect_refused('and cannot produce one for a resident at another facility', $$
  SELECT resident_record_export('e3000000-0000-0000-0000-000000000003')
$$);
RESET ROLE;

SELECT expect('the export is audited as a read, as a consequence rather than a courtesy',
  (SELECT count(*) >= 1 FROM audit_events
   WHERE action = 'residents.read'
     AND resident_id = 'e1000000-0000-0000-0000-000000000001'));


-- ── the agreement that has to be in place first ────────────────────────────────
--
-- The package modelled every agreement flowing down and nothing about the one flowing up.
-- A facility could be created and a resident admitted into it with no business associate
-- agreement, and the vendor register would have said every downstream agreement was signed
-- and been right.

\echo ''
\echo '── admitting a resident'

\set QUIET on
INSERT INTO facility_agreements (facility_id, executed_on, notification_contact,
                                 notification_days, counterparty)
VALUES ('f1000000-0000-0000-0000-000000000001', current_date - 30,
        'compliance@cedar.example', 30, 'Cedar House Operating Company'),
       ('f2000000-0000-0000-0000-000000000002', current_date - 30,
        'compliance@birch.example', 60, 'Birch House Operating Company');

-- Aspen is the building being set up: a manager, no agreement, and nobody admitted. It is
-- what the gate is for, and it is a separate person and a separate building so that the
-- checks above about who sees whom keep counting what they were counting.
INSERT INTO users (id, email, display_name) VALUES
  ('e0000000-0000-0000-0000-00000000000e', 'sam@aspen.test', 'Sam');
INSERT INTO facility_members (id, facility_id, user_id, role, state) VALUES
  ('fc000000-0000-0000-0000-00000000000c', 'f3000000-0000-0000-0000-000000000003',
   'e0000000-0000-0000-0000-00000000000e', 'care_manager', 'active');
\set QUIET off

SELECT expect('the two running buildings are covered and the one being set up is not',
  facility_is_covered('f1000000-0000-0000-0000-000000000001')
  AND facility_is_covered('f2000000-0000-0000-0000-000000000002')
  AND NOT facility_is_covered('f3000000-0000-0000-0000-000000000003'));

SET ROLE dailycare_app;
SELECT set_config('app.user_id', 'b0000000-0000-0000-0000-00000000000b', false) \gset
\set QUIET on
INSERT INTO residents (facility_id, display_name)
VALUES ('f1000000-0000-0000-0000-000000000001', 'Admitted under an agreement');
\set QUIET off
SELECT expect_rows('a manager admits a resident into a covered facility', 1,
  $$SELECT id FROM residents WHERE display_name = 'Admitted under an agreement'$$);
RESET ROLE;

SET ROLE dailycare_app;
SELECT set_config('app.user_id', 'e0000000-0000-0000-0000-00000000000e', false) \gset
SELECT expect_refused('and the manager at the uncovered building is refused one', $$
  INSERT INTO residents (facility_id, display_name)
  VALUES ('f3000000-0000-0000-0000-000000000003', 'Admitted under nothing')
$$);
RESET ROLE;

\set QUIET on
INSERT INTO facility_agreements (facility_id, executed_on, notification_contact, counterparty)
VALUES ('f3000000-0000-0000-0000-000000000003', current_date + 30, 'later@example', 'Signed, starts next month');
\set QUIET off
SELECT expect('an agreement dated next month does not cover today',
  NOT facility_is_covered('f3000000-0000-0000-0000-000000000003'));

SET ROLE dailycare_app;
SELECT set_config('app.user_id', 'e0000000-0000-0000-0000-00000000000e', false) \gset
SELECT expect_refused('so admission is still refused the day before it starts', $$
  INSERT INTO residents (facility_id, display_name)
  VALUES ('f3000000-0000-0000-0000-000000000003', 'Admitted a month early')
$$);
RESET ROLE;

SELECT expect_rows('no resident is held under no agreement', 0,
  'SELECT * FROM residents_without_agreement');

-- The situation nothing else would notice: the contract ends and the records stay.
\set QUIET on
UPDATE facility_agreements SET terminated_on = current_date
WHERE facility_id = 'f1000000-0000-0000-0000-000000000001';
\set QUIET off

SELECT expect_rows('terminating an agreement with residents inside is reported', 1,
  'SELECT * FROM agreements_expiring_with_residents');

SELECT expect('and those residents now show as held under nothing',
  (SELECT count(*) > 0 FROM residents_without_agreement));

\set QUIET on
UPDATE facility_agreements SET terminated_on = NULL
WHERE facility_id = 'f1000000-0000-0000-0000-000000000001';
\set QUIET off
SELECT expect_rows('put back', 0, 'SELECT * FROM residents_without_agreement');


-- ── the tables that say who people are ─────────────────────────────────────────
--
-- Nine tables forced row-level security and twenty-five did not, and the twenty-five
-- included users, facility_members, assignments, facilities, sessions and the trail. The
-- application has to read users to sign anybody in, and the moment it could, it could read
-- every staff and family address at every customer. The access matrix did not notice,
-- because it asked only about tables with a PHI column and these are identifying.
--
-- Before this, every row below read four users, two facilities and three memberships.

\echo ''
\echo '── what each person can see of everybody else'

SET ROLE dailycare_app;
SELECT set_config('app.user_id', 'a0000000-0000-0000-0000-00000000000a', false) \gset
SELECT expect_rows('a caregiver sees herself and her colleague at her building', 2,
  'SELECT id FROM users');
SELECT expect_rows('one building', 1, 'SELECT id FROM facilities');
SELECT expect_rows('and not the other building''s caregiver', 0,
  $$SELECT id FROM users WHERE email = 'ben@example.test'$$);
RESET ROLE;

SET ROLE dailycare_app;
SELECT set_config('app.user_id', 'b0000000-0000-0000-0000-00000000000b', false) \gset
SELECT expect_rows('a manager sees her staff and the family she granted access to', 3,
  'SELECT id FROM users');
SELECT expect_rows('and the memberships at her facility', 2, 'SELECT id FROM facility_members');
RESET ROLE;

SET ROLE dailycare_app;
SELECT set_config('app.user_id', 'c0000000-0000-0000-0000-00000000000c', false) \gset
SELECT expect_rows('a family member sees herself and nobody else', 1, 'SELECT id FROM users');
SELECT expect_rows('the building her mother is in', 1, 'SELECT id FROM facilities');
SELECT expect_rows('and no memberships, because she is not employed by anybody', 0,
  'SELECT id FROM facility_members');
RESET ROLE;

SET ROLE dailycare_app;
SELECT set_config('app.user_id', 'd0000000-0000-0000-0000-00000000000d', false) \gset
SELECT expect_rows('a caregiver at the other building sees only himself', 1,
  'SELECT id FROM users');
SELECT expect_rows('and not the first building', 0,
  $$SELECT id FROM facilities WHERE name = 'Cedar House'$$);
RESET ROLE;

SELECT set_config('app.user_id', '', false) \gset
SET ROLE dailycare_app;
SELECT expect_rows('an unidentified request sees no people', 0, 'SELECT id FROM users');
SELECT expect_rows('no buildings', 0, 'SELECT id FROM facilities');
SELECT expect_rows('and no memberships', 0, 'SELECT id FROM facility_members');
RESET ROLE;


-- ── credentials are not application data ───────────────────────────────────────

\echo ''
\echo '── sessions and tokens'

\set QUIET on
INSERT INTO sessions (user_id, refresh_hash, device_label, expires_at) VALUES
  ('a0000000-0000-0000-0000-00000000000a', md5('one') || md5('two'), 'her phone',
   now() + interval '30 days');
INSERT INTO user_tokens (user_id, purpose, token_hash, expires_at) VALUES
  ('c0000000-0000-0000-0000-00000000000c', 'invitation', md5('t1') || md5('t2'),
   now() + interval '7 days');
\set QUIET off

SET ROLE dailycare_app;
SELECT set_config('app.user_id', 'a0000000-0000-0000-0000-00000000000a', false) \gset
SELECT expect_rows('a person sees the devices they are signed in on', 1, 'SELECT id FROM sessions');
RESET ROLE;

SET ROLE dailycare_app;
SELECT set_config('app.user_id', 'b0000000-0000-0000-0000-00000000000b', false) \gset
SELECT expect_rows('and not a colleague''s', 0, 'SELECT id FROM sessions');
-- Refused outright rather than filtered: the baseline in grants.sql gives the application
-- no privilege on this table at all, so the policy never has to decide.
SELECT expect_refused('nobody reads an invitation token through the application',
  $$SELECT id FROM user_tokens$$);
RESET ROLE;


-- ── a photograph row is not taken on trust ─────────────────────────────────────
--
-- From an independent review. The insert policy checked who the resident was and nothing
-- about the row: any bucket, any path, any uploader, and a deleted_at already set - which
-- is a row the next retention run removes without the object being touched, leaving a
-- photograph in a bucket with nothing that knows whose it was.

\echo ''
\echo '── what may be claimed about a photograph'

SET ROLE dailycare_app;
SELECT set_config('app.user_id', 'a0000000-0000-0000-0000-00000000000a', false) \gset

SELECT expect_refused('a row that already claims its object is gone', $$
  INSERT INTO media_objects (facility_id, resident_id, bucket, object_path, content_type,
                             byte_size, uploaded_by, deleted_at)
  VALUES ('f1000000-0000-0000-0000-000000000001','e1000000-0000-0000-0000-000000000001',
          'dailycare-media','f1000000-0000-0000-0000-000000000001/a.jpg','image/jpeg',10,
          'a0000000-0000-0000-0000-00000000000a', now())
$$);

SELECT expect_refused('an upload attributed to a colleague', $$
  INSERT INTO media_objects (facility_id, resident_id, bucket, object_path, content_type,
                             byte_size, uploaded_by)
  VALUES ('f1000000-0000-0000-0000-000000000001','e1000000-0000-0000-0000-000000000001',
          'dailycare-media','f1000000-0000-0000-0000-000000000001/b.jpg','image/jpeg',10,
          'b0000000-0000-0000-0000-00000000000b')
$$);

SELECT expect_refused('a path that belongs to another building', $$
  INSERT INTO media_objects (facility_id, resident_id, bucket, object_path, content_type,
                             byte_size, uploaded_by)
  VALUES ('f1000000-0000-0000-0000-000000000001','e1000000-0000-0000-0000-000000000001',
          'dailycare-media','f2000000-0000-0000-0000-000000000002/c.jpg','image/jpeg',10,
          'a0000000-0000-0000-0000-00000000000a')
$$);

SELECT expect('and an ordinary upload still works, so none of that is "no inserts"',
  (SELECT count(*) >= 0 FROM media_objects));
\set QUIET on
INSERT INTO media_objects (facility_id, resident_id, bucket, object_path, content_type,
                           byte_size, uploaded_by)
VALUES ('f1000000-0000-0000-0000-000000000001','e1000000-0000-0000-0000-000000000001',
        'dailycare-media','f1000000-0000-0000-0000-000000000001/ok.jpg','image/jpeg',10,
        'a0000000-0000-0000-0000-00000000000a');
\set QUIET off
SELECT expect_rows('the ordinary upload is there', 1,
  $$SELECT * FROM media_objects WHERE object_path LIKE '%ok.jpg'$$);
RESET ROLE;


-- ── the clinical feed, which could not write at all ────────────────────────────
--
-- The matrix said the feed may insert a medication event with a source and a reference.
-- The database said nothing may: medication_events forces row-level security, its one
-- insert policy required source = 'caregiver', and dailycare_integration had no grant
-- anywhere in the model. A claim the package made and did not back.

\echo ''
\echo '── the clinical feed'

SET ROLE dailycare_integration;

SELECT expect('the feed can find the resident a patient id was matched to, without reading one',
  resident_for_external('pointclickcare', 'PCC-77')
  = 'e1000000-0000-0000-0000-000000000001');

-- Refused outright rather than returning nothing, because the feed has no grant on the
-- table at all. The stronger of the two answers.
SELECT expect_refused('and cannot read a resident', $$SELECT id FROM residents$$);

\set QUIET on
INSERT INTO medication_events (facility_id, resident_id, care_date, slot, status,
                               occurred_at, source, source_ref)
VALUES ('f1000000-0000-0000-0000-000000000001','e1000000-0000-0000-0000-000000000001',
        DATE '2026-09-12','am','given', now(), 'pointclickcare','MAR-1');
\set QUIET off
SELECT expect_rows('it can write the row it exists to write', 1,
  $$SELECT id FROM medication_events WHERE source_ref = 'MAR-1'$$);

SELECT expect_refused('but not one that looks like a caregiver''s', $$
  INSERT INTO medication_events (facility_id, resident_id, care_date, slot, status, source)
  VALUES ('f1000000-0000-0000-0000-000000000001','e1000000-0000-0000-0000-000000000001',
          DATE '2026-09-13','pm','given','caregiver')
$$);

SELECT expect_refused('nor one with no reference back to the record it came from', $$
  INSERT INTO medication_events (facility_id, resident_id, care_date, slot, status, source)
  VALUES ('f1000000-0000-0000-0000-000000000001','e1000000-0000-0000-0000-000000000001',
          DATE '2026-09-13','pm','given','pointclickcare')
$$);

SELECT expect_refused('and it cannot read a care note', $$
  SELECT note FROM care_days LIMIT 1
$$);
RESET ROLE;


-- ── a filed record cannot be rewritten ─────────────────────────────────────────
--
-- An independent review of this model reproduced both of these. They are here as checks
-- rather than as a note because the guarantee they protect was stated in three places and
-- enforced in none: the policy restricted which rows could be updated and said nothing
-- about which columns, so a caregiver could replace a note, reassign its authorship, and
-- leave nothing behind - the audit trail records column names and never their contents,
-- which is right, and which means a rewrite is unrecoverable.

\echo ''
\echo '── what a caregiver may do to a day she filed'

SET ROLE dailycare_app;
SELECT set_config('app.user_id', 'a0000000-0000-0000-0000-00000000000a', false) \gset

SELECT expect_refused('rewriting the note on a day she filed', $$
  UPDATE care_days SET note = 'Settled evening, no concerns.'
  WHERE id = 'cd000000-0000-0000-0000-000000000001'
$$);

SELECT expect_refused('or reassigning who filed it', $$
  UPDATE care_days SET filed_by = 'b0000000-0000-0000-0000-00000000000b'
  WHERE id = 'cd000000-0000-0000-0000-000000000001'
$$);

SELECT expect_refused('or changing a clinical value on it', $$
  UPDATE care_days SET mood = 'calm', sleep = 'slept_well'
  WHERE id = 'cd000000-0000-0000-0000-000000000001'
$$);

SELECT expect_refused('or filing a day in a colleague''s name', $$
  INSERT INTO care_days (facility_id, resident_id, care_date, mood, appetite, sleep, filed_by)
  VALUES ('f1000000-0000-0000-0000-000000000001','e1000000-0000-0000-0000-000000000001',
          DATE '2026-09-10','calm','good','slept_well','b0000000-0000-0000-0000-00000000000b')
$$);

-- The one update that is allowed, so the refusals above are not simply "no updates work".
\set QUIET on
UPDATE care_days SET superseded_at = now() WHERE id = 'cd000000-0000-0000-0000-000000000001';
\set QUIET off
SELECT expect('retiring a day is allowed, which is the whole of what update is for',
  (SELECT superseded_at IS NOT NULL FROM care_days
   WHERE id = 'cd000000-0000-0000-0000-000000000001'));

SELECT expect_refused('and making a retired day current again is not', $$
  UPDATE care_days SET superseded_at = NULL
  WHERE id = 'cd000000-0000-0000-0000-000000000001'
$$);
RESET ROLE;

SELECT expect('the note she filed is still the note that is there',
  (SELECT count(*) = 1 FROM care_days
   WHERE id = 'cd000000-0000-0000-0000-000000000001' AND mood = 'calm'));


-- ── a row cannot name a resident in another facility ───────────────────────────
--
-- Also from the independent review. Every child of a resident carries facility_id and
-- resident_id as separate references; each one held, and nothing said the pair belonged
-- together. A manager at one building inserted a contact row naming their own facility and
-- a resident at another, named themself in it, and read that resident's record.

\echo ''
\echo '── and what a manager may do with two identifiers that do not agree'

SET ROLE dailycare_app;
SELECT set_config('app.user_id', 'b0000000-0000-0000-0000-00000000000b', false) \gset

SELECT expect_refused('granting herself access to a resident at another facility', $$
  INSERT INTO resident_contacts (facility_id, resident_id, user_id, relation, state, granted_at)
  VALUES ('f1000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000003',
          'b0000000-0000-0000-0000-00000000000b','other_family','active',now())
$$);

SELECT expect_refused('assigning one of her caregivers to a resident at another facility', $$
  INSERT INTO assignments (facility_id, resident_id, facility_member_id)
  VALUES ('f1000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000003',
          'fa000000-0000-0000-0000-00000000000a')
$$);

SELECT expect_refused('filing a care day against a resident at another facility', $$
  INSERT INTO care_days (facility_id, resident_id, care_date, mood, appetite, sleep, filed_by)
  VALUES ('f1000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000003',
          DATE '2026-09-11','calm','good','slept_well','b0000000-0000-0000-0000-00000000000b')
$$);

SELECT expect_refused('or a medication event against one', $$
  INSERT INTO medication_events (facility_id, resident_id, care_date, slot, status, source, recorded_by)
  VALUES ('f1000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000003',
          DATE '2026-09-11','am','given','caregiver','b0000000-0000-0000-0000-00000000000b')
$$);
RESET ROLE;

SELECT expect_refused('and a resident cannot be moved into another building by an update', $$
  UPDATE residents SET facility_id = 'f2000000-0000-0000-0000-000000000002'
  WHERE id = 'e1000000-0000-0000-0000-000000000001'
$$);

SELECT expect('so Mabel at the other facility is still only hers',
  (SELECT count(*) = 0 FROM resident_contacts
   WHERE resident_id = 'e3000000-0000-0000-0000-000000000003'));

-- And put the table-level DELETE back the way it was found. It was granted above so that
-- the refusals were the policies' doing rather than a missing grant; leaving it granted
-- would make the baseline checks below report drift this file caused itself.
\set QUIET on
REVOKE DELETE ON residents, resident_contacts, care_days, care_day_meals,
  care_day_concerns, medication_events, media_objects FROM dailycare_app;
\set QUIET off

SELECT expect('and the grant this file borrowed has been given back',
  (SELECT count(*) = 0 FROM app_can_delete));


-- ── what the application is granted, as opposed to what it may reach ───────────
--
-- Row-level security decides which rows. Grants decide which tables and which columns, and
-- no file in the model said anything about the second - the only grants were in these
-- suites, and they were GRANT SELECT, INSERT, UPDATE ON ALL TABLES. A test scaffold
-- standing in for a production decision nobody had made.

\echo ''
\echo '── the grant baseline'

SELECT expect_rows('nothing granted that is not declared, and nothing declared that is not granted',
  0, 'SELECT * FROM grant_drift');

SELECT expect_rows('the application can delete from nothing', 0, 'SELECT * FROM app_can_delete');

SELECT expect_rows('and owns nothing, which is what FORCE was standing in for', 0,
  'SELECT * FROM app_owns_something');

SELECT expect_rows('and reaches no part of the compliance register', 0,
  'SELECT * FROM app_reaches_the_register');

-- PostgreSQL 14 reads a view with its owner's privileges, so this is the shape that turns
-- every policy in this file off for one path without raising anything.
SELECT expect_rows('and reaches no policy-protected table through a view', 0,
  'SELECT * FROM app_reads_rls_through_a_view');

-- Taken at the top of this file, before checks_begin() lifted FORCE. See the comment there.
--
-- ENABLE applies the policies to everybody but the table's owner; FORCE applies them to
-- the owner too, and on Cloud SQL the owner is postgres - an ordinary role, not a
-- superuser. So the difference is whether one role reads every row of a PHI table.
--
-- Either direction is a change nobody wrote down. The seed job made the harmless-looking
-- one: it lifted FORCE on assignments to write its fixtures and turned it ON afterwards,
-- which the model never asked for. Nothing failed, because every suite builds its own
-- database from the model and none of them ever looked at a seeded one.
SELECT expect_rows('row security is forced on exactly the tables that declare it', 0,
  'SELECT * FROM rls_drift_at_start');

-- PostgreSQL 14 grants CREATE on schema public to PUBLIC at initdb, so until
-- schema-privileges.sql ran, every role in the cluster could create objects in the schema
-- the application reads. Tested before it existed: as dailycare_app, CREATE TABLE in
-- public was accepted and the table came back owned by dailycare_app - a place to put
-- rows where no policy, no column grant and no audit trigger in this directory applies.
SELECT expect_rows('PUBLIC cannot create in the schema the application reads', 0,
  'SELECT * FROM schema_privilege_drift');

SET ROLE dailycare_app;
SELECT expect_refused('the application creating a table of its own', $$
  CREATE TABLE somewhere_outside_the_model (id int, note text)
$$);
SELECT expect_refused('or a function, which would run as whoever called it', $$
  CREATE FUNCTION somewhere_outside_the_model() RETURNS int LANGUAGE sql AS 'SELECT 1'
$$);
RESET ROLE;

-- It reads what it is granted, which is the half that has to keep working.
SELECT expect('and it can still read the schema it was granted USAGE on',
  has_schema_privilege('dailycare_app', 'public', 'USAGE'));


SELECT expect('the baseline is not empty, which would make all four of those cheap',
  (SELECT count(*) >= 30 FROM app_privileges));

-- The column-level half, which is the second statement of the amend-by-adding rule: the
-- trigger refuses a rewrite, and this means the request never reaches the trigger.
SELECT expect('update on a filed day is superseded_at and nothing else',
  (SELECT columns = ARRAY['superseded_at'] FROM app_privileges
   WHERE table_name = 'care_days' AND privilege = 'UPDATE'));

SELECT expect('and a resident''s facility is not among the columns that may change',
  (SELECT NOT ('facility_id' = ANY(columns)) FROM app_privileges
   WHERE table_name = 'residents' AND privilege = 'UPDATE'));

-- Proving the drift view can see, in both directions.
SELECT expect_noticed('somebody grants a privilege by hand',
  $$GRANT DELETE ON residents TO dailycare_app$$, 'grant_drift');

SELECT expect_noticed('or writes one down and never applies it',
  $$INSERT INTO app_privileges (grantee, table_name, privilege)
    VALUES ('dailycare_app','vendors','SELECT')$$, 'grant_drift');

SELECT expect_rows('and the probes left the baseline as it was', 0, 'SELECT * FROM grant_drift');


-- ── the classic way a definer function is turned against its own database ──────
--
-- A SECURITY DEFINER function runs with the privileges of whoever wrote it. If it calls
-- anything unqualified, a caller who controls search_path can put their own function in
-- front of the real one and have it run as the definer. Every one of these functions
-- exists to answer a question about who may see a resident, so that would be the whole
-- access model.
--
-- It also breaks something much more ordinary: pg_dump restores with an empty search_path,
-- so an unqualified call inside a function body fails during a restore. That is how this
-- was found - the database could not be restored from its own dump.

\echo ''
\echo '── definer functions cannot be redirected'

SELECT expect_rows('every SECURITY DEFINER function pins its own search_path', 0,
  $$SELECT p.proname FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.prosecdef
      AND NOT coalesce(array_to_string(p.proconfig, ',') LIKE '%search_path%', false)$$);

-- A lower bound rather than a total. The point of this line is that the one above is not
-- passing over an empty set; pinning the exact number turns every new definer function
-- into a failing check that says nothing about what changed.
SELECT expect('and there are definer functions, which would make that cheap otherwise',
  (SELECT count(*) >= 11 FROM pg_proc p
   JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.prosecdef));

SELECT expect_rows('so does every function the model calls from a constraint or a trigger', 0,
  $$SELECT p.proname FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    JOIN pg_language l ON l.oid = p.prolang
    WHERE n.nspname = 'public' AND l.lanname = 'plpgsql'
      AND p.proname IN ('reject_unhashed_credential','notification_body_is_safe',
                        'audit_phi_write','scrub_phi','apply_retention')
      AND NOT coalesce(array_to_string(p.proconfig, ',') LIKE '%search_path%', false)$$);


-- ── the matrix and the database agree ──────────────────────────────────────────

\echo ''
\echo '── the access matrix against the catalogue it describes'

SELECT expect_rows('every actor has an answer for every table and every operation', 0,
  'SELECT * FROM access_matrix_blanks');

SELECT expect('and the matrix is not empty, which would make that cheap',
  (SELECT count(*) >= 192 FROM access_matrix));

-- The stronger statement, and the one that does not go stale: every table holding a
-- resident's record has an answer for every actor and every operation. That is
-- access_matrix_blanks above; this says the set it is drawn from is the real one.
SELECT expect('and it covers every table that holds a resident record',
  NOT EXISTS (
    SELECT DISTINCT dc.table_name FROM data_classification dc
    WHERE dc.class = 'phi'
      AND dc.table_name IN (SELECT table_name FROM information_schema.tables
                            WHERE table_schema = 'public' AND table_type = 'BASE TABLE')
      AND dc.table_name NOT IN (SELECT table_name FROM access_matrix)));

SELECT expect_rows('no table permits a delete the matrix says nothing can be deleted from', 0,
  'SELECT * FROM access_matrix_delete_drift');

SELECT expect_rows('no PHI-bearing table is missing from the matrix', 0,
  'SELECT * FROM access_matrix_uncovered_tables');

\echo ''
\echo '── saying a photograph arrived'

-- The application holds UPDATE on uploaded_at, and for a while held it with no policy
-- that let it reach a row: the grant was there, the update affected nothing, and a
-- photograph sat in the bucket with the record saying it never came.
--
-- Placed before the checks that end Maria's assignment. After them she is not assigned to
-- anybody, app_may_write_resident is false, and the policy refuses her for the right
-- reason at the wrong moment - which reads exactly like the policy being broken.

-- Maria's photograph of her own resident, uploaded and not yet confirmed. Seeded as the
-- owner because the point is what the application may do to it, not how it got there -
-- and RESET ROLE first, because earlier checks in this file leave one set and an insert
-- made as the application would be refused by the policy it is here to exercise.
\set QUIET on
RESET ROLE;
INSERT INTO media_objects (id, facility_id, resident_id, bucket, object_path,
                           content_type, byte_size, uploaded_by)
VALUES ('4e000000-0000-0000-0000-00000000000e',
        'f1000000-0000-0000-0000-000000000001',
        'e1000000-0000-0000-0000-000000000001',
        'dailycare-media-prod',
        'f1000000-0000-0000-0000-000000000001/2026/just-uploaded.jpg',
        'image/jpeg', 180, 'a0000000-0000-0000-0000-00000000000a');

SET ROLE dailycare_app;
-- false, not true. The third argument means transaction-local, and psql runs each
-- statement in its own - so a local setting is gone by the next line, and a policy then
-- reads as refusing the caller when what happened is there was no caller at all.
SELECT set_config('app.user_id', 'a0000000-0000-0000-0000-00000000000a', false);
\set QUIET off

-- A data-modifying statement cannot live inside a subquery in PostgreSQL, so each of
-- these is a CTE and the check reads the count it returned.
WITH said AS (
  UPDATE media_objects SET uploaded_at = now()
   WHERE id = '4e000000-0000-0000-0000-00000000000e' AND uploaded_at IS NULL
   RETURNING 1)
SELECT expect('a caregiver can say the photograph they uploaded arrived',
  (SELECT count(*) = 1 FROM said));

WITH again AS (
  UPDATE media_objects SET uploaded_at = now()
   WHERE id = '4e000000-0000-0000-0000-00000000000e'
   RETURNING 1)
SELECT expect('and cannot say it twice', (SELECT count(*) = 0 FROM again));

-- The one that would undo the retention handshake: marking an object gone without
-- anything having removed it from the bucket.
--
-- Refused by the privilege rather than by the policy, which is the stronger of the two -
-- the request never reaches a row to be judged. The column grant on media_objects names
-- checksum and uploaded_at and not deleted_at, so this is the grant and the policy saying
-- the same thing twice, and the outer one answering first.
DO $$
BEGIN
  UPDATE media_objects SET deleted_at = now()
   WHERE id = '4e000000-0000-0000-0000-00000000000e';
  RAISE NOTICE 'FAIL  ALLOWED: the application marked a photograph deleted';
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'PASS  refused: the application cannot mark a photograph deleted';
END $$;

\set QUIET on
RESET ROLE;
\set QUIET off

\echo ''
\echo '── the matrix as the reviewer reads it'
SELECT table_name, operation, caregiver, care_manager, family FROM access_matrix_report
WHERE table_name IN ('residents','care_days','media_objects') ORDER BY table_name, operation;


\echo ''
\echo '── putting somebody in the building'

-- facility_members decides who exists, and until member-invitation.sql nothing but
-- bootstrap could write to it. Every check below runs as dailycare_app with an identity
-- set, never as the owner: the identity tables are ENABLE rather than FORCE, so the owner
-- is exempt from their policies and would pass all of this without any of it being true.
-- That exemption is what hid the contact activation for a release.
--
-- The refusals are read as row counts rather than as exceptions wherever they are updates.
-- An INSERT a policy refuses raises 42501; an UPDATE it refuses matches no rows and says
-- nothing at all, which is the asymmetry that makes a check here easy to write wrongly.

SET ROLE dailycare_app;

-- Priya, care manager at Cedar.
SELECT set_config('app.user_id', 'b0000000-0000-0000-0000-00000000000b', false);

-- The application names the account. It has to: the read policies on users are myself, a
-- colleague, and a family member I granted access to, and somebody with no membership yet
-- is none of the three - so the manager who just created this row cannot see it, and asking
-- for its id back is not a thing that works. The check below is the one that says so.
INSERT INTO users (id, email, display_name)
VALUES ('aa000000-0000-0000-0000-0000000000aa', 'tomas@example.test', 'Tomas');

SELECT expect_rows('an account a manager has just created is not yet visible to them', 0,
  $$SELECT id FROM users WHERE email = 'tomas@example.test'$$);

INSERT INTO facility_members (facility_id, user_id, role, invited_by)
VALUES ('f1000000-0000-0000-0000-000000000001', 'aa000000-0000-0000-0000-0000000000aa',
        'caregiver', 'b0000000-0000-0000-0000-00000000000b');

-- Two things at once, and the second is why this is not circular: the membership carries a
-- foreign key to users, so a row that was never written could not have been referenced.
SELECT expect_rows('and is a colleague once it belongs to a building', 1,
  $$SELECT id FROM users WHERE email = 'tomas@example.test'$$);

SELECT expect('the membership opens invited, which is the column default and not a choice',
  (SELECT state = 'invited' AND ended_at IS NULL
     FROM facility_members fm JOIN users u ON u.id = fm.user_id
    WHERE u.email = 'tomas@example.test'));

SELECT expect('and records who let them in',
  (SELECT invited_by = 'b0000000-0000-0000-0000-00000000000b'
     FROM facility_members fm JOIN users u ON u.id = fm.user_id
    WHERE u.email = 'tomas@example.test'));

-- The whole of what 'invited' is worth. Every predicate the policies are built from wants
-- 'active', so until the person accepts there is nothing the membership opens.
SELECT set_config('app.user_id',
  (SELECT id::text FROM users u WHERE u.email = 'tomas@example.test'), false);
SELECT expect_rows('an invited caregiver sees no residents', 0, 'SELECT id FROM residents');
SELECT expect_rows('and no care days',                       0, 'SELECT id FROM care_days');

-- Aimed at: the same manager, the same statement, another building.
SELECT set_config('app.user_id', 'b0000000-0000-0000-0000-00000000000b', false);
SELECT expect_refused('a manager cannot put somebody into a building they do not manage',
  $$INSERT INTO facility_members (facility_id, user_id, role, invited_by)
    VALUES ('f2000000-0000-0000-0000-000000000002',
            'a0000000-0000-0000-0000-00000000000a', 'caregiver',
            'b0000000-0000-0000-0000-00000000000b')$$);

SELECT expect_refused('and cannot name somebody else as the one who invited them',
  $$INSERT INTO facility_members (facility_id, user_id, role, invited_by)
    VALUES ('f1000000-0000-0000-0000-000000000001',
            'c0000000-0000-0000-0000-00000000000c', 'caregiver',
            'a0000000-0000-0000-0000-00000000000a')$$);

-- A caregiver is not an administrator. Maria files care.
SELECT set_config('app.user_id', 'a0000000-0000-0000-0000-00000000000a', false);
SELECT expect_refused('a caregiver cannot create an account',
  $$INSERT INTO users (email, display_name) VALUES ('nope@example.test', 'Nope')$$);
SELECT expect_refused('and cannot add anybody to the building',
  $$INSERT INTO facility_members (facility_id, user_id, role, invited_by)
    VALUES ('f1000000-0000-0000-0000-000000000001',
            'c0000000-0000-0000-0000-00000000000c', 'caregiver',
            'a0000000-0000-0000-0000-00000000000a')$$);

-- The columns that are not in the grant. Refused before a policy is reached, which is the
-- stronger of the two answers.
SELECT set_config('app.user_id', 'b0000000-0000-0000-0000-00000000000b', false);
DO $probe$
BEGIN
  INSERT INTO users (email, display_name, password_hash)
  VALUES ('forged@example.test', 'Forged', '$argon2id$v=19$m=65536,t=3,p=4$c29tZXNhbHQ$aaaa');
  RAISE NOTICE 'FAIL  ALLOWED: the inviter set a password';
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'PASS  refused: the inviter cannot set a password';
END $probe$;

DO $probe$
BEGIN
  INSERT INTO facility_members (facility_id, user_id, role, invited_by, state)
  VALUES ('f1000000-0000-0000-0000-000000000001',
          'c0000000-0000-0000-0000-00000000000c', 'caregiver',
          'b0000000-0000-0000-0000-00000000000b', 'active');
  RAISE NOTICE 'FAIL  ALLOWED: a membership was created already active';
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'PASS  refused: a membership cannot be created already active';
END $probe$;


-- ── and taking somebody out of it again ────────────────────────────────────────
--
-- Read as row counts throughout. A refused UPDATE matches nothing and raises nothing, so
-- expect_refused() would report "ALLOWED" for a statement the database silently dropped -
-- the one place in this file where the obvious helper is the wrong one.

UPDATE facility_members SET state = 'revoked', ended_at = now(), updated_at = now()
 WHERE user_id = 'aa000000-0000-0000-0000-0000000000aa';

SELECT expect('a care manager ends a membership, and it is a date rather than a deletion',
  (SELECT state = 'revoked' AND ended_at IS NOT NULL
     FROM facility_members WHERE user_id = 'aa000000-0000-0000-0000-0000000000aa'));

SELECT expect('and the row is still there to be asked who invited them',
  (SELECT invited_by = 'b0000000-0000-0000-0000-00000000000b'
     FROM facility_members WHERE user_id = 'aa000000-0000-0000-0000-0000000000aa'));

-- Priya is the only care manager at Cedar, so ending her own membership would leave the
-- building with no way to run it and no way back except the terminal this milestone exists
-- to retire.
UPDATE facility_members SET state = 'revoked', ended_at = now(), updated_at = now()
 WHERE id = 'fb000000-0000-0000-0000-00000000000b';

SELECT expect('the last care manager at a building cannot end their own membership',
  (SELECT state = 'active' AND ended_at IS NULL
     FROM facility_members WHERE id = 'fb000000-0000-0000-0000-00000000000b'));

-- Birch is Ben's building and not Priya's. Read back as the owner rather than as Priya,
-- because members_own_facilities does not show her Birch at all - asking her whether the row
-- changed returns no row, and a check that reads nothing reports whatever NULL reports. The
-- first version of this did exactly that and called a working policy a failure.
UPDATE facility_members SET state = 'revoked', ended_at = now(), updated_at = now()
 WHERE id = 'fd000000-0000-0000-0000-00000000000d';

RESET ROLE;
SELECT expect('and a manager cannot end a membership at a building they do not manage',
  (SELECT state = 'active' AND ended_at IS NULL
     FROM facility_members WHERE id = 'fd000000-0000-0000-0000-00000000000d'));
SET ROLE dailycare_app;
SELECT set_config('app.user_id', 'b0000000-0000-0000-0000-00000000000b', false);

-- Ending is one defined transition, pinned at both ends because a policy cannot compare the
-- row before with the row after. Setting a date without revoking is not it.
--
-- This one raises where the three above were silent, and the difference is which half
-- refused: USING filters the rows a statement may reach and says nothing about the ones it
-- removes, WITH CHECK judges the row that would result and raises when it fails. Same
-- policy, two behaviours, and a check written for the wrong one passes while proving
-- nothing.
SELECT expect_refused('a membership is not quietly ended without being revoked',
  $$UPDATE facility_members SET ended_at = now(), updated_at = now()
     WHERE user_id = 'a0000000-0000-0000-0000-00000000000a'$$);

-- The columns no path writes. Refused by the grant, before a row is reached.
DO $probe$
BEGIN
  UPDATE facility_members SET role = 'care_manager'
   WHERE id = 'fa000000-0000-0000-0000-00000000000a';
  RAISE NOTICE 'FAIL  ALLOWED: a caregiver was promoted by an update';
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'PASS  refused: somebody does not become a care manager by an update';
END $probe$;

DO $probe$
BEGIN
  UPDATE facility_members SET facility_id = 'f2000000-0000-0000-0000-000000000002'
   WHERE id = 'fa000000-0000-0000-0000-00000000000a';
  RAISE NOTICE 'FAIL  ALLOWED: a membership moved buildings';
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'PASS  refused: a membership does not move to another building by an update';
END $probe$;

DO $probe$
BEGIN
  UPDATE facility_members SET invited_by = 'a0000000-0000-0000-0000-00000000000a'
   WHERE id = 'fa000000-0000-0000-0000-00000000000a';
  RAISE NOTICE 'FAIL  ALLOWED: the record of who let somebody in was rewritten';
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'PASS  refused: who let somebody in is not rewritable';
END $probe$;

-- ── the grant on its own, with the policy satisfied ───────────────────────────
--
-- The three probes above are refused twice over, and that is the design: the column grant
-- says a request may not name these, and the policies would refuse the row anyway. It also
-- makes them unable to say which half did it - both answer 42501, so widening the grant
-- changes nothing a check can see, and it was widening the grant that showed this.
--
-- So each of these satisfies the policy completely and names one column the grant leaves
-- out. Nothing but the grant can refuse them, which is what makes them worth running.

DO $probe$
BEGIN
  INSERT INTO facility_members (facility_id, user_id, role, invited_by, state)
  VALUES ('f1000000-0000-0000-0000-000000000001',
          'c0000000-0000-0000-0000-00000000000c', 'caregiver',
          'b0000000-0000-0000-0000-00000000000b', 'invited');
  RAISE NOTICE 'FAIL  ALLOWED: a request named state, even to say what the default says';
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'PASS  refused by the grant alone: a request cannot name state at all';
END $probe$;

DO $probe$
BEGIN
  INSERT INTO facility_members (facility_id, user_id, role, invited_by, started_at)
  VALUES ('f1000000-0000-0000-0000-000000000001',
          'c0000000-0000-0000-0000-00000000000c', 'caregiver',
          'b0000000-0000-0000-0000-00000000000b', now() - interval '1 year');
  RAISE NOTICE 'FAIL  ALLOWED: a membership was backdated';
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'PASS  refused by the grant alone: a membership cannot be backdated';
END $probe$;

-- A valid ending in every respect the policy judges, carrying one column it does not.
DO $probe$
BEGIN
  UPDATE facility_members
     SET state = 'revoked', ended_at = now(), updated_at = now(), role = 'care_manager'
   WHERE user_id = 'a0000000-0000-0000-0000-00000000000a';
  RAISE NOTICE 'FAIL  ALLOWED: a promotion rode along with an ending';
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'PASS  refused by the grant alone: a role cannot ride along with an ending';
END $probe$;

SELECT expect_refused('and nothing anywhere deletes a membership',
  $$DELETE FROM facility_members WHERE id = 'fa000000-0000-0000-0000-00000000000a'$$);


-- ── and putting one of them in front of a resident ────────────────────────────
--
-- assignments_manager_writes was written with the rest of the policies and nothing could
-- reach it: the application held SELECT and UPDATE (ended_at) on this table and no INSERT,
-- so the first of these would have failed on the grant before the policy was consulted.

INSERT INTO assignments (facility_id, resident_id, facility_member_id, assigned_by)
VALUES ('f1000000-0000-0000-0000-000000000001', 'e2000000-0000-0000-0000-000000000002',
        'fa000000-0000-0000-0000-00000000000a', 'b0000000-0000-0000-0000-00000000000b');

SELECT expect('a care manager puts a caregiver in front of a resident',
  (SELECT count(*) = 1 FROM assignments
    WHERE resident_id = 'e2000000-0000-0000-0000-000000000002'
      AND facility_member_id = 'fa000000-0000-0000-0000-00000000000a'));

-- The question a reviewer asks, and the reason the column is pinned rather than trusted.
SELECT expect('and the record says who did it',
  (SELECT assigned_by = 'b0000000-0000-0000-0000-00000000000b' FROM assignments
    WHERE resident_id = 'e2000000-0000-0000-0000-000000000002'
      AND facility_member_id = 'fa000000-0000-0000-0000-00000000000a'));

SELECT expect_refused('an assignment cannot be attributed to somebody else',
  $$INSERT INTO assignments (facility_id, resident_id, facility_member_id, assigned_by)
    VALUES ('f1000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001',
            'fb000000-0000-0000-0000-00000000000b', 'a0000000-0000-0000-0000-00000000000a')$$);

SELECT expect_refused('and cannot be made with no author at all',
  $$INSERT INTO assignments (facility_id, resident_id, facility_member_id)
    VALUES ('f1000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001',
            'fb000000-0000-0000-0000-00000000000b')$$);

-- Refused by the grant rather than by the policy, which the policy also says. Measured by
-- removing the policy's clause and watching nothing go red: ended_at is outside the insert
-- grant, so the request never reaches a row to be judged. Labelled for what actually answers.
SELECT expect_refused('an assignment cannot be created already over, which the grant refuses',
  $$INSERT INTO assignments (facility_id, resident_id, facility_member_id, assigned_by, ended_at)
    VALUES ('f1000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001',
            'fb000000-0000-0000-0000-00000000000b', 'b0000000-0000-0000-0000-00000000000b',
            now())$$);

SELECT expect_refused('and not in a building the manager does not manage',
  $$INSERT INTO assignments (facility_id, resident_id, facility_member_id, assigned_by)
    VALUES ('f2000000-0000-0000-0000-000000000002', 'e3000000-0000-0000-0000-000000000003',
            'fd000000-0000-0000-0000-00000000000d', 'b0000000-0000-0000-0000-00000000000b')$$);

-- Satisfies the policy in every respect it judges, and names one column the grant leaves
-- out. Nothing but the grant can refuse it.
DO $probe$
BEGIN
  INSERT INTO assignments (facility_id, resident_id, facility_member_id, assigned_by, started_at)
  VALUES ('f1000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001',
          'fb000000-0000-0000-0000-00000000000b', 'b0000000-0000-0000-0000-00000000000b',
          now() - interval '1 year');
  RAISE NOTICE 'FAIL  ALLOWED: an assignment was backdated';
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'PASS  refused by the grant alone: an assignment cannot be backdated';
END $probe$;

-- A caregiver files care. Who reads a resident is not theirs to decide.
SELECT set_config('app.user_id', 'a0000000-0000-0000-0000-00000000000a', false);
SELECT expect_refused('a caregiver cannot assign anybody to anybody',
  $$INSERT INTO assignments (facility_id, resident_id, facility_member_id, assigned_by)
    VALUES ('f1000000-0000-0000-0000-000000000001', 'e2000000-0000-0000-0000-000000000002',
            'fa000000-0000-0000-0000-00000000000a', 'a0000000-0000-0000-0000-00000000000a')$$);

-- And the same question on the other disclosure. bootstrap set granted_by correctly and had
-- a commit named for it; this is the half that does not depend on which handler wrote it.
SELECT set_config('app.user_id', 'b0000000-0000-0000-0000-00000000000b', false);
SELECT expect_refused('a family grant cannot be attributed to somebody else',
  $$INSERT INTO resident_contacts
      (facility_id, resident_id, user_id, relation, granted_by, granted_at)
    VALUES ('f1000000-0000-0000-0000-000000000001', 'e2000000-0000-0000-0000-000000000002',
            'c0000000-0000-0000-0000-00000000000c', 'child',
            'a0000000-0000-0000-0000-00000000000a', now())$$);

INSERT INTO resident_contacts
  (facility_id, resident_id, user_id, relation, granted_by, granted_at)
VALUES ('f1000000-0000-0000-0000-000000000001', 'e2000000-0000-0000-0000-000000000002',
        'c0000000-0000-0000-0000-00000000000c', 'child',
        'b0000000-0000-0000-0000-00000000000b', now());

SELECT expect('and one made by the manager making it is accepted',
  (SELECT granted_by = 'b0000000-0000-0000-0000-00000000000b' FROM resident_contacts
    WHERE resident_id = 'e2000000-0000-0000-0000-000000000002'
      AND user_id = 'c0000000-0000-0000-0000-00000000000c'));


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
\echo '── a caregiver who leaves, without losing what they filed'

-- The milestone's own sentence, and the one clause in it that is a promise rather than a
-- feature. Proved by doing it and reading the records back rather than by pointing at
-- ON DELETE RESTRICT, which is what makes it possible and not what makes it true.
--
-- Its own building, seeded here rather than reusing Cedar. Everything above has been
-- revoking things in sequence, so a check written against that state could pass because
-- somebody had already been taken off something three sections earlier - which is a check
-- passing for the wrong reason, and the thing this suite exists to catch.

RESET ROLE;
\set QUIET on
INSERT INTO facilities (id, name, timezone) VALUES
  ('f9000000-0000-0000-0000-000000000009', 'Willow House', 'America/Chicago');
INSERT INTO facility_agreements
  (facility_id, executed_on, notification_contact, notification_days, counterparty)
VALUES ('f9000000-0000-0000-0000-000000000009', current_date - 30,
        'compliance@willow.test', 30, 'Willow House');
INSERT INTO users (id, email, display_name) VALUES
  ('91000000-0000-0000-0000-000000000091', 'nora@willow.test', 'Nora'),
  ('92000000-0000-0000-0000-000000000092', 'sam@willow.test',  'Sam');
INSERT INTO facility_members (id, facility_id, user_id, role, state) VALUES
  ('81000000-0000-0000-0000-000000000081', 'f9000000-0000-0000-0000-000000000009',
   '91000000-0000-0000-0000-000000000091', 'care_manager', 'active'),
  ('82000000-0000-0000-0000-000000000082', 'f9000000-0000-0000-0000-000000000009',
   '92000000-0000-0000-0000-000000000092', 'caregiver', 'active');
INSERT INTO residents (id, facility_id, display_name) VALUES
  ('93000000-0000-0000-0000-000000000093', 'f9000000-0000-0000-0000-000000000009', 'Ruth');
INSERT INTO assignments (facility_id, resident_id, facility_member_id) VALUES
  ('f9000000-0000-0000-0000-000000000009', '93000000-0000-0000-0000-000000000093',
   '82000000-0000-0000-0000-000000000082');
INSERT INTO sessions (user_id, refresh_hash, device_label, expires_at) VALUES
  ('92000000-0000-0000-0000-000000000092', repeat('9', 64), 'sam phone',
   now() + interval '30 days');
\set QUIET off

SET ROLE dailycare_app;
SELECT set_config('app.user_id', '92000000-0000-0000-0000-000000000092', false);
SELECT expect_rows('while Sam works here he reads the resident he is assigned to', 1,
  $$SELECT id FROM residents WHERE id = '93000000-0000-0000-0000-000000000093'$$);
SELECT expect('and his session works', session_is_valid(repeat('9', 64)));

-- Filed as Sam, through the policy, rather than seeded as the owner. The first version of
-- this seeded it and the trail check failed, correctly: the audit trigger takes its actor
-- from app.user_id, and a row the owner wrote with nobody set names nobody. A check for
-- "the trail still attributes him" is only worth running if he wrote the row.
INSERT INTO care_days
  (id, facility_id, resident_id, care_date, mood, appetite, sleep, note, filed_by) VALUES
  ('94000000-0000-0000-0000-000000000094', 'f9000000-0000-0000-0000-000000000009',
   '93000000-0000-0000-0000-000000000093', current_date - 2, 'calm', 'good', 'slept_well',
   'A quiet afternoon in the garden.', '92000000-0000-0000-0000-000000000092');
SELECT expect('and the day he files is his',
  (SELECT filed_by = '92000000-0000-0000-0000-000000000092' FROM care_days
    WHERE id = '94000000-0000-0000-0000-000000000094'));

-- Ended through the policy milestone five added, as the manager, rather than by the owner
-- reaching past it. The point is the state a care manager can actually produce.
SELECT set_config('app.user_id', '91000000-0000-0000-0000-000000000091', false);
UPDATE facility_members SET state = 'revoked', ended_at = now(), updated_at = now()
 WHERE id = '82000000-0000-0000-0000-000000000082';
SELECT expect('a care manager ends the membership',
  (SELECT ended_at IS NOT NULL FROM facility_members
    WHERE id = '82000000-0000-0000-0000-000000000082'));

-- The four halves of the promise, read back as the manager who remains.
SELECT expect_rows('the day he filed still reads', 1,
  $$SELECT id FROM care_days WHERE id = '94000000-0000-0000-0000-000000000094'$$);

SELECT expect('with the note he wrote on it',
  (SELECT note = 'A quiet afternoon in the garden.' FROM care_days
    WHERE id = '94000000-0000-0000-0000-000000000094'));

SELECT expect('and his name still resolves on it',
  care_day_filed_by_name('94000000-0000-0000-0000-000000000094') = 'Sam');

SELECT expect('the trail still attributes the writes to him',
  (SELECT count(*) > 0 FROM audit_events
    WHERE actor_user_id = '92000000-0000-0000-0000-000000000092'));

-- The same question the application asks, which is a different question: internal/records
-- reads the trail through a LEFT JOIN on users, so a row survives whether or not the name
-- behind it resolves. The comment there says a writer who has left comes back without a
-- name. app_shares_a_facility does not filter on the other person's state, so that should
-- not be what happens - and this is where the two are made to agree or disagree out loud.
SELECT expect('and the name on those rows resolves for the manager reading them',
  (SELECT count(*) > 0 FROM audit_events a
     JOIN users u ON u.id = a.actor_user_id
    WHERE a.actor_user_id = '92000000-0000-0000-0000-000000000092'
      AND u.display_name = 'Sam'));

SELECT expect('and they are filed against the resident, which is what the trail reads by',
  (SELECT count(*) > 0 FROM audit_events
    WHERE actor_user_id = '92000000-0000-0000-0000-000000000092'
      AND resident_id   = '93000000-0000-0000-0000-000000000093'));

SELECT expect('and he is still in the building rather than gone from it',
  (SELECT count(*) = 1 FROM facility_members
    WHERE id = '82000000-0000-0000-0000-000000000082'));

-- And what he can see, which is the other half: the record keeps him, he does not keep it.
SELECT set_config('app.user_id', '92000000-0000-0000-0000-000000000092', false);
SELECT expect_rows('he reads no residents the moment it ends', 0, 'SELECT id FROM residents');
SELECT expect_rows('and none of their days',                   0, 'SELECT id FROM care_days');

-- A membership ending is not the same act as an account closing, and only the second stops
-- a phone. Both are in the card's sentence and this is where they come apart.
SELECT expect('his phone still works, because ending a membership is not closing an account',
  session_is_valid(repeat('9', 64)));

RESET ROLE;
\set QUIET on
UPDATE users SET deactivated_at = now() WHERE id = '92000000-0000-0000-0000-000000000092';
\set QUIET off
SET ROLE dailycare_app;

SELECT expect('closing the account is what stops it', NOT session_is_valid(repeat('9', 64)));

SELECT set_config('app.user_id', '91000000-0000-0000-0000-000000000091', false);
SELECT expect('and the day he filed is untouched by any of it',
  care_day_filed_by_name('94000000-0000-0000-0000-000000000094') = 'Sam');


\echo ''
\echo '── access taken back, and offered again'

-- Three transitions, three policies, and none of them able to do another's work. The one
-- that was missing is the middle; the one that was too wide was the first.

RESET ROLE;
\set QUIET on
INSERT INTO users (id, email, display_name) VALUES
  ('95000000-0000-0000-0000-000000000095', 'ruths-daughter@example.test', 'Esther');
\set QUIET off
SET ROLE dailycare_app;
SELECT set_config('app.user_id', '91000000-0000-0000-0000-000000000091', false);

INSERT INTO resident_contacts
  (id, facility_id, resident_id, user_id, relation, granted_by, granted_at)
VALUES ('96000000-0000-0000-0000-000000000096', 'f9000000-0000-0000-0000-000000000009',
        '93000000-0000-0000-0000-000000000093', '95000000-0000-0000-0000-000000000095',
        'child', app_user_id(), now());

SELECT expect('a grant opens at invited, which is the column default and not a choice',
  (SELECT state = 'invited' FROM resident_contacts
    WHERE id = '96000000-0000-0000-0000-000000000096'));

-- The hole contacts_update had. A manager could turn a disclosure on for somebody who had
-- never accepted it; nothing did, and now nothing can.
--
-- This one raises where the membership refusals were silent, and which half catches it is
-- why: contacts_withdraw admits any row that is not already revoked, so an invited grant
-- reaches WITH CHECK, and WITH CHECK judges the row that would result and raises. The same
-- policy refuses silently when USING is what removes the row. Whether a refusal is loud
-- depends on the state the row is in, which is a reason to read both halves before writing
-- a check rather than after - this one was written as a read-back first and errored.
SELECT expect_refused('and a manager cannot accept it on their behalf',
  $$UPDATE resident_contacts SET state = 'active', updated_at = now()
     WHERE id = '96000000-0000-0000-0000-000000000096'$$);

-- The person's own, which contact-acceptance.sql wrote and nothing had exercised from here.
SELECT set_config('app.user_id', '95000000-0000-0000-0000-000000000095', false);
UPDATE resident_contacts SET state = 'active', updated_at = now()
 WHERE id = '96000000-0000-0000-0000-000000000096';
SELECT expect('accepting is hers and it works',
  (SELECT state = 'active' FROM resident_contacts
    WHERE id = '96000000-0000-0000-0000-000000000096'));
SELECT expect_rows('and now she reads her mother', 1,
  $$SELECT id FROM residents WHERE id = '93000000-0000-0000-0000-000000000093'$$);

-- Withdrawing.
SELECT set_config('app.user_id', '91000000-0000-0000-0000-000000000091', false);
UPDATE resident_contacts
   SET state = 'revoked', revoked_by = app_user_id(), revoked_at = now(), updated_at = now()
 WHERE id = '96000000-0000-0000-0000-000000000096';
SELECT expect('a manager takes it back, and the row says who did',
  (SELECT state = 'revoked' AND revoked_at IS NOT NULL
      AND revoked_by = '91000000-0000-0000-0000-000000000091'
     FROM resident_contacts WHERE id = '96000000-0000-0000-0000-000000000096'));

SELECT set_config('app.user_id', '95000000-0000-0000-0000-000000000095', false);
SELECT expect_rows('and she reads nobody', 0, 'SELECT id FROM residents');

-- Restoring, which lands where a grant starts rather than where it ended.
SELECT set_config('app.user_id', '91000000-0000-0000-0000-000000000091', false);
SELECT expect_refused('a manager cannot restore it straight to active',
  $$UPDATE resident_contacts SET state = 'active', updated_at = now()
     WHERE id = '96000000-0000-0000-0000-000000000096'$$);
SELECT expect('and it is still revoked after the attempt',
  (SELECT state = 'revoked' FROM resident_contacts
    WHERE id = '96000000-0000-0000-0000-000000000096'));

UPDATE resident_contacts SET state = 'invited', updated_at = now()
 WHERE id = '96000000-0000-0000-0000-000000000096';
SELECT expect('and offers it again, waiting for her',
  (SELECT state = 'invited' FROM resident_contacts
    WHERE id = '96000000-0000-0000-0000-000000000096'));

SELECT expect('with the withdrawal still on the row, which is what says it was offered again',
  (SELECT revoked_at IS NOT NULL AND revoked_by = '91000000-0000-0000-0000-000000000091'
     FROM resident_contacts WHERE id = '96000000-0000-0000-0000-000000000096'));

SELECT set_config('app.user_id', '95000000-0000-0000-0000-000000000095', false);
SELECT expect_rows('she still reads nobody until she accepts', 0, 'SELECT id FROM residents');

-- And can see who is asking, which she could not before facilities_offered: the screen that
-- shows her a pending grant has to name the building, and the policy built on
-- app_my_contact_facilities() wants 'active' - so the one person a waiting grant is for was
-- the one person who could not read whose it was.
SELECT expect_rows('and can read the name of the building asking her', 1,
  $$SELECT id FROM facilities WHERE id = 'f9000000-0000-0000-0000-000000000009'$$);
SELECT expect_rows('and still none of the residents in it', 0, 'SELECT id FROM residents');
UPDATE resident_contacts SET state = 'active', updated_at = now()
 WHERE id = '96000000-0000-0000-0000-000000000096';
SELECT expect_rows('and reads her mother again once she has', 1,
  $$SELECT id FROM residents WHERE id = '93000000-0000-0000-0000-000000000093'$$);

-- As the manager. The first version of these two ran as Esther, whose identity the line
-- above left set, and both reported ALLOWED - because no policy admits her to this row at
-- all, so the update matched nothing and raised nothing. A refusal by the wrong half, read
-- by the wrong helper, looks exactly like the thing it was written to catch.
SELECT set_config('app.user_id', '91000000-0000-0000-0000-000000000091', false);

-- Who took it back is pinned the same way who gave it is. Measured by removing the clause
-- and watching nothing go red, which is how this check came to exist: the block proved the
-- column was written correctly and never that it could not be written otherwise.
SELECT expect_refused('a withdrawal cannot be attributed to somebody else',
  $$UPDATE resident_contacts
       SET state = 'revoked', revoked_by = '95000000-0000-0000-0000-000000000095',
           revoked_at = now(), updated_at = now()
     WHERE id = '96000000-0000-0000-0000-000000000096'$$);

-- The date spelled out rather than left off. Leaving it off proves nothing on this row:
-- it has been withdrawn once already and still carries that date, so the clause is
-- satisfied by history rather than by the statement. Written as NULL, it asks the question.
SELECT expect_refused('and cannot be made with no date on it',
  $$UPDATE resident_contacts
       SET state = 'revoked', revoked_by = app_user_id(), revoked_at = NULL,
           updated_at = now()
     WHERE id = '96000000-0000-0000-0000-000000000096'$$);

-- The two columns no path writes any more. Refused by the grant with the policy satisfied,
-- which is the only way to ask the grant anything on its own.
DO $probe$
BEGIN
  UPDATE resident_contacts
     SET state = 'revoked', revoked_by = app_user_id(), revoked_at = now(),
         updated_at = now(), granted_by = '95000000-0000-0000-0000-000000000095'
   WHERE id = '96000000-0000-0000-0000-000000000096';
  RAISE NOTICE 'FAIL  ALLOWED: who made the grant was rewritten';
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'PASS  refused by the grant alone: who made a grant is not rewritable';
END $probe$;

\echo ''
RESET ROLE;
SELECT checks_end();
DROP FUNCTION expect(text, boolean);
DROP FUNCTION expect_noticed(text, text, text);
DROP FUNCTION expect_rows(text, int, text);
DROP FUNCTION expect_refused(text, text);
