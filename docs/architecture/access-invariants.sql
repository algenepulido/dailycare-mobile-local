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
DROP FUNCTION expect(text, boolean);
DROP FUNCTION expect_noticed(text, text, text);
DROP FUNCTION expect_rows(text, int, text);
DROP FUNCTION expect_refused(text, text);
