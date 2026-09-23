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


-- ── photographs ────────────────────────────────────────────────────────────────

-- Cathy's day is 66666666; Robert is 77777777 and has no day here.
SELECT must_reject('a photograph of one resident attached to another resident''s day', $$
  INSERT INTO media_objects (facility_id, resident_id, care_day_id, bucket, object_path,
         content_type, byte_size, uploaded_by)
  VALUES ('11111111-1111-1111-1111-111111111111', '77777777-7777-7777-7777-777777777777',
          '66666666-6666-6666-6666-666666666666', 'dc-media',
          '11111111-1111-1111-1111-111111111111/robert/1.jpg', 'image/jpeg', 1,
          '22222222-2222-2222-2222-222222222222')
$$);

SELECT must_accept('a photograph on its own resident''s day', $$
  INSERT INTO media_objects (facility_id, resident_id, care_day_id, bucket, object_path,
         content_type, byte_size, uploaded_by)
  VALUES ('11111111-1111-1111-1111-111111111111', '55555555-5555-5555-5555-555555555555',
          '66666666-6666-6666-6666-666666666666', 'dc-media',
          '11111111-1111-1111-1111-111111111111/cathy/1.jpg', 'image/jpeg', 1,
          '22222222-2222-2222-2222-222222222222')
$$);

-- A photograph taken before the day was filed has nowhere to hang yet, and the upload
-- should not have to wait for one. The pair is only checked once there is a day named.
SELECT must_accept('a photograph attached to no day at all', $$
  INSERT INTO media_objects (facility_id, resident_id, care_day_id, bucket, object_path,
         content_type, byte_size, uploaded_by)
  VALUES ('11111111-1111-1111-1111-111111111111', '55555555-5555-5555-5555-555555555555',
          NULL, 'dc-media', '11111111-1111-1111-1111-111111111111/cathy/2.jpg',
          'image/jpeg', 1, '22222222-2222-2222-2222-222222222222')
$$);

-- The path is what a signed URL is minted for. A row whose path points outside its own
-- facility would mint a link to another building's photograph.
SELECT must_reject('an object path outside the facility the row belongs to', $$
  INSERT INTO media_objects (facility_id, resident_id, bucket, object_path,
         content_type, byte_size, uploaded_by)
  VALUES ('11111111-1111-1111-1111-111111111111', '55555555-5555-5555-5555-555555555555',
          'dc-media', '99999999-9999-9999-9999-999999999999/cathy/3.jpg', 'image/jpeg', 1,
          '22222222-2222-2222-2222-222222222222')
$$);

-- A correction makes a new care_days row. The photograph stays on the row it was filed
-- against, so the current revision of a corrected day has no photograph of its own - and
-- that is what these two checks are for. Not a defect: the revisions of a day are a chain,
-- and the photograph belongs to the day rather than to one telling of it. It is a trap,
-- though, and it is the obvious query that falls into it. A read path written as
--
--     WHERE care_day_id = <the current row>
--
-- shows a family nothing the moment a caregiver fixes a typo. Resolving by the resident
-- and the date instead reaches every revision, which is what the partial unique index on
-- (resident_id, care_date) already assumes a day is.
--
-- 66666666 was superseded further up this file, and the photograph above is attached to
-- it, so the fixture is already a corrected day.
SELECT expect('a corrected day has no photograph under its current row',
  NOT EXISTS (
    SELECT 1 FROM media_objects m
    JOIN care_days cd ON cd.id = m.care_day_id
    WHERE cd.resident_id = '55555555-5555-5555-5555-555555555555'
      AND cd.care_date = '2026-09-14'
      AND cd.superseded_at IS NULL));

SELECT expect('and the same photograph is found by the resident and the date',
  EXISTS (
    SELECT 1 FROM media_objects m
    JOIN care_days cd ON cd.id = m.care_day_id
    WHERE cd.resident_id = '55555555-5555-5555-5555-555555555555'
      AND cd.care_date = '2026-09-14'));

-- Gone before it arrived is not a state.
SELECT must_reject('a photograph marked deleted that never arrived', $$
  INSERT INTO media_objects (facility_id, resident_id, bucket, object_path,
         content_type, byte_size, uploaded_by, deleted_at)
  VALUES ('11111111-1111-1111-1111-111111111111', '55555555-5555-5555-5555-555555555555',
          'dc-media', '11111111-1111-1111-1111-111111111111/cathy/4.jpg', 'image/jpeg', 1,
          '22222222-2222-2222-2222-222222222222', now())
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


-- The grant and the trigger are two statements of the same rule, and the grant is the
-- narrower of the two on purpose: reject_record_rewrite is generic and permits updated_at
-- because other tables need it, while on a filed day superseded_at already is the
-- timestamp of the only change a row can undergo.
--
-- What must hold is that the grant never exceeds the trigger. Wider, and a column could be
-- changed that the rule was written to protect; narrower is a deliberate second opinion.
SELECT expect('the columns a filed day may have updated are within what the trigger allows',
  NOT EXISTS (
    SELECT 1
      FROM information_schema.role_column_grants g
     WHERE g.grantee = 'dailycare_app' AND g.table_name = 'care_days'
       AND g.privilege_type = 'UPDATE'
       AND g.column_name::text <> ALL (
             SELECT unnest(string_to_array(encode(t.tgargs, 'escape'), '\000'))
               FROM pg_trigger t
              WHERE t.tgname = 'care_days_are_amended_not_rewritten')));

SELECT checks_end();
DROP FUNCTION must_reject(text, text);
DROP FUNCTION must_accept(text, text);
DROP FUNCTION expect(text, boolean);
DROP FUNCTION refusal_text(text);
