-- Invariant checks for schema.sql
--
-- The rules the schema is supposed to enforce, written as the smallest statements that
-- prove it, and self-reporting so the output says PASS or FAIL rather than needing to be
-- read against a list of expectations.
--
--   createdb dc_schema_check
--   psql -v ON_ERROR_STOP=1 -d dc_schema_check -f schema.sql
--   psql -d dc_schema_check -f schema-invariants.sql
--   dropdb dc_schema_check
--
-- A migration that turns any PASS into a FAIL has removed a guarantee something relies
-- on. That may be the right thing to do — but it should be a decision, not a discovery.

\set QUIET on
SET client_min_messages TO notice;
-- Lift FORCE for this suite so that it behaves the same run by a superuser and run by a
-- managed-instance owner. See checks-support.sql: the policies stay in force, and every
-- check that tests one does it by becoming the role it is about.
SELECT checks_begin();

-- Each check that must be rejected runs inside its own block. If the statement raises,
-- the constraint did its job; if it succeeds, the block falls through and says so.
CREATE OR REPLACE FUNCTION must_reject(label text, stmt text) RETURNS void AS $$
BEGIN
  BEGIN
    EXECUTE stmt;
  EXCEPTION
    WHEN unique_violation OR check_violation OR foreign_key_violation OR not_null_violation THEN
      RAISE NOTICE 'PASS  rejected: %', label;
      RETURN;
  END;
  RAISE NOTICE 'FAIL  ACCEPTED, and should not have: %', label;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION must_accept(label text, stmt text) RETURNS void AS $$
BEGIN
  EXECUTE stmt;
  RAISE NOTICE 'PASS  accepted: %', label;
EXCEPTION WHEN others THEN
  RAISE NOTICE 'FAIL  REJECTED, and should not have: % (%)', label, SQLERRM;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION expect(label text, condition boolean) RETURNS void AS $$
BEGIN
  IF condition THEN RAISE NOTICE 'PASS  %', label;
  ELSE            RAISE NOTICE 'FAIL  %', label;
  END IF;
END; $$ LANGUAGE plpgsql;

-- Everything the server would hand back about a refusal: the message, the detail line that
-- quotes the failing row, and the hint. What the application would log, if it logs errors.
CREATE OR REPLACE FUNCTION refusal_text(stmt text) RETURNS text AS $$
DECLARE msg text; det text; hnt text;
BEGIN
  EXECUTE stmt;
  RETURN '<accepted>';
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS msg = MESSAGE_TEXT, det = PG_EXCEPTION_DETAIL, hnt = PG_EXCEPTION_HINT;
  RETURN coalesce(msg,'') || ' ' || coalesce(det,'') || ' ' || coalesce(hnt,'');
END; $$ LANGUAGE plpgsql;
\set QUIET off


-- ── fixtures ───────────────────────────────────────────────────────────────────

INSERT INTO facilities (id, name, timezone) VALUES
  ('11111111-1111-1111-1111-111111111111', 'Cedar House', 'America/Chicago');

INSERT INTO users (id, email, display_name) VALUES
  ('22222222-2222-2222-2222-222222222222', 'caregiver@example.test', 'Maria'),
  ('33333333-3333-3333-3333-333333333333', 'family@example.test',    'Anna');

INSERT INTO facility_members (id, facility_id, user_id, role, state) VALUES
  ('44444444-4444-4444-4444-444444444444',
   '11111111-1111-1111-1111-111111111111',
   '22222222-2222-2222-2222-222222222222', 'caregiver', 'active');

INSERT INTO residents (id, facility_id, display_name) VALUES
  ('55555555-5555-5555-5555-555555555555', '11111111-1111-1111-1111-111111111111', 'Cathy'),
  ('77777777-7777-7777-7777-777777777777', '11111111-1111-1111-1111-111111111111', 'Robert');

INSERT INTO care_days (id, facility_id, resident_id, care_date, mood, appetite, sleep, filed_by)
VALUES ('66666666-6666-6666-6666-666666666666',
        '11111111-1111-1111-1111-111111111111',
        '55555555-5555-5555-5555-555555555555',
        '2026-09-14', 'calm', 'fair', 'restless',
        '22222222-2222-2222-2222-222222222222');


-- ── the care record ────────────────────────────────────────────────────────────

SELECT must_reject('a second current care day for the same resident and date', $$
  INSERT INTO care_days (facility_id, resident_id, care_date, mood, appetite, sleep, filed_by)
  VALUES ('11111111-1111-1111-1111-111111111111', '55555555-5555-5555-5555-555555555555',
          '2026-09-14', 'anxious', 'poor', 'up_a_lot', '22222222-2222-2222-2222-222222222222')
$$);

UPDATE care_days SET superseded_at = now() WHERE id = '66666666-6666-6666-6666-666666666666';

SELECT must_accept('an amendment once the original is superseded', $$
  INSERT INTO care_days (facility_id, resident_id, care_date, mood, appetite, sleep, filed_by, amends_id)
  VALUES ('11111111-1111-1111-1111-111111111111', '55555555-5555-5555-5555-555555555555',
          '2026-09-14', 'anxious', 'poor', 'up_a_lot', '22222222-2222-2222-2222-222222222222',
          '66666666-6666-6666-6666-666666666666')
$$);

SELECT must_reject('a meal amount when the meal did not happen', $$
  INSERT INTO care_day_meals (care_day_id, slot, happened, amount)
  VALUES ('66666666-6666-6666-6666-666666666666', 'breakfast', false, 'half')
$$);

SELECT must_accept('a meal ticked with no amount — not observed is a real answer', $$
  INSERT INTO care_day_meals (care_day_id, slot, happened, amount)
  VALUES ('66666666-6666-6666-6666-666666666666', 'breakfast', true, NULL)
$$);


-- ── medication ─────────────────────────────────────────────────────────────────

SELECT must_reject('an external medication event with no reference to its source record', $$
  INSERT INTO medication_events (facility_id, resident_id, care_date, slot, status, source)
  VALUES ('11111111-1111-1111-1111-111111111111', '55555555-5555-5555-5555-555555555555',
          '2026-09-14', 'am', 'given', 'pointclickcare')
$$);

SELECT must_accept('the AM slot recorded once', $$
  INSERT INTO medication_events (facility_id, resident_id, care_date, slot, status, source, recorded_by)
  VALUES ('11111111-1111-1111-1111-111111111111', '55555555-5555-5555-5555-555555555555',
          '2026-09-14', 'am', 'given', 'caregiver', '22222222-2222-2222-2222-222222222222')
$$);

SELECT must_reject('the AM slot recorded twice in one day', $$
  INSERT INTO medication_events (facility_id, resident_id, care_date, slot, status, source, recorded_by)
  VALUES ('11111111-1111-1111-1111-111111111111', '55555555-5555-5555-5555-555555555555',
          '2026-09-14', 'am', 'refused', 'caregiver', '22222222-2222-2222-2222-222222222222')
$$);

SELECT must_accept('two supplemental doses in one day', $$
  INSERT INTO medication_events (facility_id, resident_id, care_date, slot, status, source, recorded_by, detail)
  VALUES ('11111111-1111-1111-1111-111111111111', '55555555-5555-5555-5555-555555555555',
          '2026-09-14', 'supplemental', 'given', 'caregiver',
          '22222222-2222-2222-2222-222222222222', 'Paracetamol 500mg'),
         ('11111111-1111-1111-1111-111111111111', '55555555-5555-5555-5555-555555555555',
          '2026-09-14', 'supplemental', 'given', 'caregiver',
          '22222222-2222-2222-2222-222222222222', 'Antacid')
$$);

SELECT must_reject('a supplemental dose that does not say what it was', $$
  INSERT INTO medication_events (facility_id, resident_id, care_date, slot, status, source, recorded_by)
  VALUES ('11111111-1111-1111-1111-111111111111', '55555555-5555-5555-5555-555555555555',
          '2026-09-14', 'supplemental', 'given', 'caregiver', '22222222-2222-2222-2222-222222222222')
$$);


-- ── family access ──────────────────────────────────────────────────────────────

SELECT must_accept('a daughter granted access to her mother', $$
  INSERT INTO resident_contacts (facility_id, resident_id, user_id, relation, state, granted_by, granted_at)
  VALUES ('11111111-1111-1111-1111-111111111111', '55555555-5555-5555-5555-555555555555',
          '33333333-3333-3333-3333-333333333333', 'child', 'active',
          '22222222-2222-2222-2222-222222222222', now())
$$);

SELECT must_reject('the same person granted twice against the same resident', $$
  INSERT INTO resident_contacts (facility_id, resident_id, user_id, relation, state)
  VALUES ('11111111-1111-1111-1111-111111111111', '55555555-5555-5555-5555-555555555555',
          '33333333-3333-3333-3333-333333333333', 'power_of_attorney', 'active')
$$);

SELECT must_accept('the same person against a second resident — two parents, one building', $$
  INSERT INTO resident_contacts (facility_id, resident_id, user_id, relation, state)
  VALUES ('11111111-1111-1111-1111-111111111111', '77777777-7777-7777-7777-777777777777',
          '33333333-3333-3333-3333-333333333333', 'child', 'active')
$$);

\echo ''
\echo '── what the family app asks for. Both residents, with the relation:'
SELECT r.display_name, rc.relation
FROM resident_contacts rc
JOIN residents r ON r.id = rc.resident_id
WHERE rc.user_id = '33333333-3333-3333-3333-333333333333'
  AND rc.state = 'active'
ORDER BY r.display_name;

UPDATE resident_contacts SET state = 'revoked', revoked_at = now()
WHERE resident_id = '77777777-7777-7777-7777-777777777777';

\echo '── after revoking one: visible to the family app, and rows retained'
SELECT
  count(*) FILTER (WHERE state = 'active') AS visible,
  count(*)                                 AS retained
FROM resident_contacts
WHERE user_id = '33333333-3333-3333-3333-333333333333';
\echo ''


-- ── external identity ──────────────────────────────────────────────────────────

SELECT must_accept('matching a resident to a PointClickCare patient', $$
  UPDATE residents SET external_source = 'pointclickcare', external_patient_id = 'PCC-001'
  WHERE id = '55555555-5555-5555-5555-555555555555'
$$);

SELECT must_reject('a second resident claiming the same clinical record', $$
  UPDATE residents SET external_source = 'pointclickcare', external_patient_id = 'PCC-001'
  WHERE id = '77777777-7777-7777-7777-777777777777'
$$);

-- ── credentials ────────────────────────────────────────────────────────────────
--
-- "Passwords are hashed" is a property of whichever handler last wrote the row. These make
-- it a property of the table, so it survives the second handler nobody remembers about -
-- an import, a seeding script, a migration written in a hurry.

\echo ''
\echo '── what a credential column will accept'

SELECT must_reject('a password stored as the user typed it', $$
  INSERT INTO users (email, display_name, password_hash)
  VALUES ('plaintext@example.test', 'Plain', 'hunter2')
$$);

SELECT must_reject('a password digest from some other algorithm', $$
  INSERT INTO users (email, display_name, password_hash)
  VALUES ('bcrypt@example.test', 'Bee', '$2b$12$K7k9Zr8aQeF3xN0pLm2sOu7yTgB1cVdEwXfHiJkLmNoPqRsTuVwXy')
$$);

SELECT must_accept('an Argon2id digest', $$
  INSERT INTO users (email, display_name, password_hash)
  VALUES ('hashed@example.test', 'Hashed',
          '$argon2id$v=19$m=65536,t=3,p=4$c29tZXNhbHR2YWx1ZQ$aGFzaHZhbHVlaGFzaHZhbHVlaGFzaHZhbHVlaGFzaA')
$$);

SELECT must_reject('a refresh token kept as the client received it', $$
  INSERT INTO sessions (user_id, refresh_hash, expires_at)
  VALUES ('22222222-2222-2222-2222-222222222222', 'rt_live_9f2a7c4e', now() + interval '30 days')
$$);

SELECT must_accept('a refresh token kept as a SHA-256 digest', $$
  INSERT INTO sessions (user_id, refresh_hash, expires_at)
  VALUES ('22222222-2222-2222-2222-222222222222', md5('one') || md5('two'),
          now() + interval '30 days')
$$);

SELECT must_reject('an invitation token digest of the wrong length', $$
  INSERT INTO user_tokens (user_id, purpose, token_hash, expires_at)
  VALUES ('22222222-2222-2222-2222-222222222222', 'invitation', 'abc123',
          now() + interval '7 days')
$$);


-- The refusal is the second half of this. A check constraint reports the failing row in
-- full, so the rejection of a plaintext password is a message containing that password -
-- on its way to wherever the application sends errors.

\echo ''
\echo '── and what the refusal says about the value it refused'

SELECT expect('the refusal repeats nothing of the password',
  position('hunter2' in refusal_text($$
    INSERT INTO users (email, display_name, password_hash)
    VALUES ('leak@example.test', 'Leak', 'hunter2')
  $$)) = 0);

SELECT expect('nor of a raw refresh token',
  position('rt_live_9f2a7c4e' in refusal_text($$
    INSERT INTO sessions (user_id, refresh_hash, expires_at)
    VALUES ('22222222-2222-2222-2222-222222222222', 'rt_live_9f2a7c4e', now() + interval '1 day')
  $$)) = 0);

\set QUIET on
ALTER TABLE users DISABLE TRIGGER reject_plaintext_password;
\set QUIET off

SELECT expect('though the constraint alone would have, which is why the trigger is there',
  position('hunter2' in refusal_text($$
    INSERT INTO users (email, display_name, password_hash)
    VALUES ('leak2@example.test', 'Leak', 'hunter2')
  $$)) > 0);

SELECT expect('and the constraint still refuses it with the trigger switched off',
  (SELECT count(*) = 0 FROM users WHERE email = 'leak2@example.test'));

\set QUIET on
ALTER TABLE users ENABLE TRIGGER reject_plaintext_password;
\set QUIET off


SELECT checks_end();
DROP FUNCTION must_reject(text, text);
DROP FUNCTION must_accept(text, text);
DROP FUNCTION expect(text, boolean);
DROP FUNCTION refusal_text(text);
