-- Environment checks for environments.sql
--
--   createdb dc_env_check
--   psql -v ON_ERROR_STOP=1 -d dc_env_check -f schema.sql
--   psql -v ON_ERROR_STOP=1 -d dc_env_check -f access-policies.sql
--   psql -v ON_ERROR_STOP=1 -d dc_env_check -f data-classification.sql
--   psql -v ON_ERROR_STOP=1 -d dc_env_check -f audit-logging.sql
--   psql -v ON_ERROR_STOP=1 -d dc_env_check -f retention.sql
--   psql -v ON_ERROR_STOP=1 -d dc_env_check -f environments.sql
--   psql -d dc_env_check -f environment-invariants.sql
--   dropdb dc_env_check
--
-- A database is filled with records that each carry a string existing nowhere else, then
-- scrubbed, then every column of every table is searched for every one of those strings.
--
-- The result that matters is zero, and a zero from a scanner nobody has seen find anything
-- means nothing at all. So one canary is planted in an operational column the scrub is not
-- supposed to touch. It has to still be there afterwards: that single check is what makes
-- the other results evidence rather than assertion.

\set QUIET on
SET client_min_messages TO notice;
-- Lift FORCE for this suite so that it behaves the same run by a superuser and run by a
-- managed-instance owner. See checks-support.sql: the policies stay in force, and every
-- check that tests one does it by becoming the role it is about.
SELECT checks_begin();

CREATE OR REPLACE FUNCTION expect(label text, condition boolean) RETURNS void AS $$
BEGIN
  IF condition THEN RAISE NOTICE 'PASS  %', label;
  ELSE            RAISE NOTICE 'FAIL  %', label;
  END IF;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION expect_rejected(label text, stmt text) RETURNS void AS $$
BEGIN
  BEGIN
    EXECUTE stmt;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'PASS  refused (%): %', SQLERRM, label; RETURN;
  END;
  RAISE NOTICE 'FAIL  ALLOWED, and should not have been: %', label;
END; $$ LANGUAGE plpgsql;
\set QUIET off


-- ── fixtures, every one of them carrying a canary ──────────────────────────────

\set QUIET on
INSERT INTO deployment (environment, label) VALUES ('production', 'live');

INSERT INTO facilities (id, name, timezone) VALUES
  ('f1000000-0000-0000-0000-000000000001', 'Cedar House CANARY-OPERATIONAL-9c2e', 'America/Chicago');

INSERT INTO retention_policies (facility_id, care_record_days, media_days, audit_days)
VALUES ('f1000000-0000-0000-0000-000000000001', 2555, 2555, 2190);

-- The credential canaries have to be the shape the schema demands, or the row never
-- lands and the check that follows would be searching an empty table. Base64 for a
-- password digest, lowercase hex for a token.
INSERT INTO users (id, email, display_name, password_hash) VALUES
  ('a0000000-0000-0000-0000-00000000000a', 'maria.CANARY-EMAIL-4b71@realdomain.test',
   'Maria CANARY-STAFFNAME-8d03',
   '$argon2id$v=19$m=65536,t=3,p=4$CANARYSECRET1f55aaaaaa$' || repeat('b', 43)),
  ('a0000000-0000-0000-0000-00000000000b', 'daniel.CANARY-EMAIL-2a90@realdomain.test',
   'Daniel CANARY-STAFFNAME-6e14',
   '$argon2id$v=19$m=65536,t=3,p=4$CANARYSECRET7b22aaaaaa$' || repeat('c', 43));

INSERT INTO facility_members (id, facility_id, user_id, role, state) VALUES
  ('fa000000-0000-0000-0000-00000000000a', 'f1000000-0000-0000-0000-000000000001',
   'a0000000-0000-0000-0000-00000000000a', 'caregiver', 'active');

INSERT INTO sessions (user_id, refresh_hash, device_label, expires_at) VALUES
  ('a0000000-0000-0000-0000-00000000000a', 'deadbeefcafe3e88' || repeat('a', 48),
   'iPhone 15 CANARY-DEVICE-5c41', now() + interval '30 days');

INSERT INTO user_tokens (user_id, purpose, token_hash, expires_at) VALUES
  ('a0000000-0000-0000-0000-00000000000a', 'invitation', 'deadbeefcafe0d76' || repeat('a', 48),
   now() + interval '7 days');

INSERT INTO residents (id, facility_id, display_name, external_source, external_patient_id,
                       admitted_on, departed_on, baseline_mood, baseline_appetite) VALUES
  ('e1000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000001',
   'Cathy CANARY-RESIDENT-7f3a', 'pointclickcare', 'PCC-CANARY-PATIENT-2b64',
   DATE '2024-03-01', NULL, 'agitated', 'poor'),
  ('e2000000-0000-0000-0000-000000000002', 'f1000000-0000-0000-0000-000000000001',
   'Dorothy CANARY-RESIDENT-1c58', NULL, NULL,
   DATE '2024-06-15', DATE '2025-11-20', 'calm', 'good');

INSERT INTO care_days (id, facility_id, resident_id, care_date, mood, appetite, sleep,
                       note, hygiene_shower, filed_by) VALUES
  ('cd000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000001',
   'e1000000-0000-0000-0000-000000000001', DATE '2026-03-01', 'agitated', 'refused',
   'didnt_sleep', 'She was frightened again tonight. CANARY-NOTE-6a19', true,
   'a0000000-0000-0000-0000-00000000000a'),
  ('cd000000-0000-0000-0000-000000000002', 'f1000000-0000-0000-0000-000000000001',
   'e1000000-0000-0000-0000-000000000001', DATE '2026-03-15', 'calm', 'good',
   'slept_well', '', false, 'a0000000-0000-0000-0000-00000000000a');

INSERT INTO care_day_meals (care_day_id, slot, happened, amount) VALUES
  ('cd000000-0000-0000-0000-000000000001', 'breakfast', true, 'a_bit'),
  ('cd000000-0000-0000-0000-000000000001', 'lunch', false, NULL);
INSERT INTO care_day_concerns (care_day_id, concern) VALUES
  ('cd000000-0000-0000-0000-000000000001', 'sundowning');

INSERT INTO medication_events (facility_id, resident_id, care_date, slot, status,
                               occurred_at, source, source_ref, detail) VALUES
  ('f1000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001',
   DATE '2026-03-01', 'am', 'given', TIMESTAMPTZ '2026-03-01 08:10-06',
   'pointclickcare', 'MAR-CANARY-SOURCEREF-4d27', NULL),
  ('f1000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001',
   DATE '2026-03-01', 'supplemental', 'given', TIMESTAMPTZ '2026-03-01 14:02-06',
   'caregiver', NULL, 'Paracetamol for hip pain. CANARY-MEDDETAIL-8e35');

INSERT INTO media_objects (facility_id, resident_id, care_day_id, bucket, object_path,
                           content_type, byte_size, uploaded_by) VALUES
  ('f1000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001',
   'cd000000-0000-0000-0000-000000000001', 'dailycare-media-prod',
   'f1000000-0000-0000-0000-000000000001/2026/CANARY-OBJECTPATH-3f82-cathy-garden.jpg', 'image/jpeg', 184320,
   'a0000000-0000-0000-0000-00000000000a');

INSERT INTO resident_contacts (facility_id, resident_id, user_id, relation, state) VALUES
  ('f1000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001',
   'a0000000-0000-0000-0000-00000000000b', 'child', 'active');

INSERT INTO audit_events (facility_id, action, subject_type, resident_id, ip_hash) VALUES
  ('f1000000-0000-0000-0000-000000000001', 'care_day.read', 'care_day',
   'e1000000-0000-0000-0000-000000000001', 'CANARY-IPHASH-5a70');

CREATE TEMP TABLE canaries (pattern text);
INSERT INTO canaries VALUES
  ('CANARY-RESIDENT-7f3a'), ('CANARY-RESIDENT-1c58'), ('CANARY-NOTE-6a19'),
  ('CANARY-EMAIL-4b71'),    ('CANARY-EMAIL-2a90'),    ('CANARY-STAFFNAME-8d03'),
  ('CANARY-STAFFNAME-6e14'),('CANARYSECRET1f55'),    ('CANARYSECRET7b22'),
  ('deadbeefcafe3e88'),     ('CANARY-DEVICE-5c41'),   ('deadbeefcafe0d76'),
  ('CANARY-PATIENT-2b64'),  ('CANARY-SOURCEREF-4d27'),('CANARY-MEDDETAIL-8e35'),
  ('CANARY-OBJECTPATH-3f82'),('CANARY-IPHASH-5a70'),  ('realdomain.test');

CREATE TEMP TABLE before_counts AS
SELECT 'residents' t, count(*) n FROM residents
UNION ALL SELECT 'care_days',         count(*) FROM care_days
UNION ALL SELECT 'care_day_meals',    count(*) FROM care_day_meals
UNION ALL SELECT 'care_day_concerns', count(*) FROM care_day_concerns
UNION ALL SELECT 'medication_events', count(*) FROM medication_events
UNION ALL SELECT 'media_objects',     count(*) FROM media_objects
UNION ALL SELECT 'resident_contacts', count(*) FROM resident_contacts
UNION ALL SELECT 'users',             count(*) FROM users
UNION ALL SELECT 'sessions',          count(*) FROM sessions
UNION ALL SELECT 'audit_events',      count(*) FROM audit_events;

CREATE TEMP TABLE before_secrets AS
SELECT 'password:' || id::text AS k, password_hash AS v FROM users
UNION ALL SELECT 'refresh:' || id::text, refresh_hash FROM sessions
UNION ALL SELECT 'token:'   || id::text, token_hash   FROM user_tokens;

CREATE TEMP TABLE before_shape AS
SELECT (SELECT care_date FROM care_days WHERE id = 'cd000000-0000-0000-0000-000000000002')
     - (SELECT care_date FROM care_days WHERE id = 'cd000000-0000-0000-0000-000000000001')
       AS gap_days,
       (SELECT care_date FROM care_days WHERE id = 'cd000000-0000-0000-0000-000000000001')
       AS first_date,
       (SELECT length(note) FROM care_days WHERE id = 'cd000000-0000-0000-0000-000000000001')
       AS note_length,
       (SELECT string_agg(mood::text, ',' ORDER BY id) FROM care_days) AS moods,
       (SELECT string_agg(status::text || '/' || slot::text, ',' ORDER BY care_date, slot)
        FROM medication_events) AS med_shape;
\set QUIET off


-- ── before anything: the rules themselves ──────────────────────────────────────

\echo ''
\echo '── the rules'

SELECT expect('every column classified phi, identifying or secret has a scrub rule',
  (SELECT count(*) = 0 FROM unscrubbed_columns));

SELECT expect('and the set is not empty, which would make the line above meaningless',
  (SELECT count(*) > 30 FROM scrub_rules));

SELECT expect('every column kept was kept for a stated reason',
  (SELECT count(*) = 0 FROM scrub_rules WHERE strategy = 'keep' AND reason IS NULL));

SELECT expect_rejected('keeping a column without saying why', $$
  INSERT INTO scrub_rules (table_name, column_name, strategy)
  VALUES ('care_days', 'filed_at', 'keep')
$$);

SELECT expect_rejected('a rule for a column the classification has never heard of', $$
  INSERT INTO scrub_rules (table_name, column_name, strategy)
  VALUES ('care_days', 'invented_column', 'null_out')
$$);


-- ── the locks ──────────────────────────────────────────────────────────────────

\echo ''
\echo '── what the scrub refuses to do'

SELECT expect_rejected('scrubbing a database labelled production', format($$
  SELECT * FROM scrub_phi(%L)
$$, current_database()));

\set QUIET on
UPDATE deployment SET environment = 'development', label = 'dev restore';
\set QUIET off

SELECT expect_rejected('scrubbing without naming the database it is connected to', $$
  SELECT * FROM scrub_phi('some-other-database')
$$);

-- The scenario this actually guards against: a migration adds a column holding PHI and
-- nobody says what happens to it when a snapshot is restored. Done by adding a real
-- column rather than by removing an existing rule, so the rule set is left as it is and
-- a rule that has been tampered with stays tampered with.
\set QUIET on
ALTER TABLE care_days ADD COLUMN pending_review_note text;
INSERT INTO data_classification (table_name, column_name, class, note)
VALUES ('care_days','pending_review_note','phi','Added by a later migration.');
\set QUIET off

SELECT expect('a PHI column added later shows up as unscrubbed',
  (SELECT count(*) = 1 FROM unscrubbed_columns
   WHERE table_name = 'care_days' AND column_name = 'pending_review_note'));

SELECT expect_rejected('scrubbing while a classified column has no rule', format($$
  SELECT * FROM scrub_phi(%L)
$$, current_database()));

\set QUIET on
DELETE FROM data_classification WHERE column_name = 'pending_review_note';
ALTER TABLE care_days DROP COLUMN pending_review_note;
\set QUIET off


-- ── the scanner has to be able to find something ───────────────────────────────

\echo ''
\echo '── the scanner, before it is trusted to return zero'

SELECT expect('it finds every canary in the unscrubbed database',
  (SELECT count(DISTINCT pattern) FROM phi_residue(ARRAY(SELECT pattern FROM canaries)))
  = (SELECT count(*) FROM canaries));

\echo '   found in:'
SELECT table_name, column_name, pattern FROM phi_residue(ARRAY(SELECT pattern FROM canaries))
ORDER BY table_name, column_name;


-- ── the scrub ──────────────────────────────────────────────────────────────────

\echo ''
\echo '── scrubbing'
-- FORCE goes back on for the scrub itself, because lifting and restoring it is part of
-- what the scrub does and is checked below. Lifted again afterwards for the owner-level
-- reads that count what is left.
\set QUIET on
SELECT checks_end();
\set QUIET off
SELECT what, changed FROM scrub_phi(current_database());
\set QUIET on
SELECT checks_begin();
\set QUIET off

\echo ''
\echo '── and now the same search'

SELECT expect('not one canary survives anywhere in the database',
  NOT EXISTS (SELECT 1 FROM phi_residue(
    ARRAY(SELECT pattern FROM canaries WHERE pattern <> 'CANARY-OPERATIONAL-9c2e'))));

\echo '   anything still found (must be empty):'
SELECT table_name, column_name, pattern, hits
FROM phi_residue(ARRAY(SELECT pattern FROM canaries));

SELECT expect('the operational canary is still there, so the scanner still works',
  EXISTS (SELECT 1 FROM phi_residue(ARRAY['CANARY-OPERATIONAL-9c2e'])));


-- ── what a developer is left with ──────────────────────────────────────────────

\echo ''
\echo '── the database is still worth developing against'

SELECT expect('nothing was deleted',
  NOT EXISTS (
    SELECT 1 FROM before_counts b
    JOIN (SELECT 'residents' t, count(*) n FROM residents
          UNION ALL SELECT 'care_days',         count(*) FROM care_days
          UNION ALL SELECT 'care_day_meals',    count(*) FROM care_day_meals
          UNION ALL SELECT 'care_day_concerns', count(*) FROM care_day_concerns
          UNION ALL SELECT 'medication_events', count(*) FROM medication_events
          UNION ALL SELECT 'media_objects',     count(*) FROM media_objects
          UNION ALL SELECT 'resident_contacts', count(*) FROM resident_contacts
          UNION ALL SELECT 'users',             count(*) FROM users
          UNION ALL SELECT 'sessions',          count(*) FROM sessions
          UNION ALL SELECT 'audit_events',      count(*) FROM audit_events) a
      ON a.t = b.t
    WHERE a.n <> b.n));

SELECT expect('every resident still has a name, and it is not the one they had',
  (SELECT count(*) = 2 FROM residents WHERE display_name ~ '^[A-Z][a-z]+ [A-Z][a-z]+$'));

SELECT expect('every login is an address that cannot receive mail',
  (SELECT count(*) = 2 FROM users WHERE email LIKE '%@example.invalid'));

SELECT expect('and the logins are still distinct from one another',
  (SELECT count(DISTINCT email) = count(*) FROM users));

SELECT expect('not one credential is the digest it was',
  NOT EXISTS (
    SELECT 1 FROM before_secrets b
    JOIN (SELECT 'password:' || id::text AS k, password_hash AS v FROM users
          UNION ALL SELECT 'refresh:' || id::text, refresh_hash FROM sessions
          UNION ALL SELECT 'token:'   || id::text, token_hash   FROM user_tokens) a
      ON a.k = b.k
    WHERE a.v IS NOT DISTINCT FROM b.v));

-- The replacement is the right shape, not a sentinel. The schema refuses anything else,
-- and a login path that has never seen a realistic digest is one nobody has tested.
SELECT expect('and every one of them is still a well-formed digest',
  (SELECT count(*) = 0 FROM users       WHERE NOT is_argon2id(password_hash))
  AND (SELECT count(*) = 0 FROM sessions    WHERE NOT is_sha256_hex(refresh_hash))
  AND (SELECT count(*) = 0 FROM user_tokens WHERE NOT is_sha256_hex(token_hash)));

SELECT expect('which means the credential triggers stayed on through the scrub',
  (SELECT count(*) = 3 FROM pg_trigger
   WHERE NOT tgisinternal AND tgfoid = 'reject_unhashed_credential'::regproc
     AND tgenabled = 'O'));

SELECT expect('the object path no longer carries a name, and still belongs to its facility',
  (SELECT object_path !~* 'cathy'
      AND object_path LIKE facility_id::text || '/%'
      AND length(object_path) = length(facility_id::text) + 17
   FROM media_objects LIMIT 1));

SELECT expect('the care note is the length it was, so a layout bug still reproduces',
  (SELECT length(note) FROM care_days WHERE id = 'cd000000-0000-0000-0000-000000000001')
  = (SELECT note_length FROM before_shape));

SELECT expect('an empty note is still empty rather than filler',
  (SELECT note = '' FROM care_days WHERE id = 'cd000000-0000-0000-0000-000000000002'));

SELECT expect('the dates moved',
  (SELECT care_date FROM care_days WHERE id = 'cd000000-0000-0000-0000-000000000001')
  <> (SELECT first_date FROM before_shape));

SELECT expect('but the interval between them did not, so a two-week report still works',
  (SELECT care_date FROM care_days WHERE id = 'cd000000-0000-0000-0000-000000000002')
  - (SELECT care_date FROM care_days WHERE id = 'cd000000-0000-0000-0000-000000000001')
  = (SELECT gap_days FROM before_shape));

SELECT expect('a resident still in the building still has no departure date',
  (SELECT departed_on IS NULL FROM residents WHERE id = 'e1000000-0000-0000-0000-000000000001'));

SELECT expect('the clinical shape is untouched, which is the point of keeping it',
  (SELECT string_agg(mood::text, ',' ORDER BY id) FROM care_days)
  = (SELECT moods FROM before_shape)
  AND (SELECT string_agg(status::text || '/' || slot::text, ',' ORDER BY care_date, slot)
       FROM medication_events) = (SELECT med_shape FROM before_shape));

SELECT expect('a meal recorded as not observed is still not observed',
  (SELECT amount IS NULL AND happened = false FROM care_day_meals
   WHERE care_day_id = 'cd000000-0000-0000-0000-000000000001' AND slot = 'lunch'));

SELECT expect('nothing was orphaned',
  NOT EXISTS (SELECT 1 FROM care_days c WHERE NOT EXISTS
                (SELECT 1 FROM residents r WHERE r.id = c.resident_id))
  AND NOT EXISTS (SELECT 1 FROM media_objects m WHERE NOT EXISTS
                (SELECT 1 FROM care_days c WHERE c.id = m.care_day_id))
  AND NOT EXISTS (SELECT 1 FROM resident_contacts rc WHERE NOT EXISTS
                (SELECT 1 FROM users u WHERE u.id = rc.user_id)));


-- ── the database is left the way it was found ──────────────────────────────────

\echo ''
\echo '── and the protections are back on'

-- Checked at the moment the scrub finished, before this suite lifted FORCE again for its
-- own reads. Seven tables went in and seven came back.
SELECT expect('row-level security is forced again on every table it was forced on',
  (SELECT count(*) FROM checks.forced_tables)
  = (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relrowsecurity)
  AND (SELECT count(*) > 7 FROM checks.forced_tables));

SELECT expect('the audit triggers are enabled again',
  (SELECT count(*) = 0 FROM pg_trigger tg
   WHERE NOT tg.tgisinternal AND tg.tgfoid = 'audit_phi_write'::regproc
     AND tg.tgenabled <> 'O'));

SELECT expect('the unique indexes dropped for the date shift came back',
  (SELECT count(*) = 2 FROM pg_class
   WHERE relname IN ('care_days_current_per_day', 'medication_events_one_per_slot')));

SELECT expect('and they still hold, which the shift could have broken',
  (SELECT count(*) = 2 FROM pg_index x JOIN pg_class i ON i.oid = x.indexrelid
   WHERE i.relname IN ('care_days_current_per_day','medication_events_one_per_slot')
     AND x.indisvalid AND x.indisunique));

SELECT expect('the run is recorded, with the offset it used',
  (SELECT count(*) = 1 FROM scrub_runs
   WHERE environment = 'development' AND shift_days < 0 AND rows_changed > 0));


-- ── who may do any of this ─────────────────────────────────────────────────────

\echo ''
\echo '── the application has no part in it'

\set QUIET on
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dailycare_app') THEN
    RAISE EXCEPTION 'role dailycare_app does not exist. Apply roles.sql first.';
  END IF;
END $$;
GRANT USAGE ON SCHEMA public TO dailycare_app;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO dailycare_app;
REVOKE ALL ON deployment, scrub_rules, scrub_runs FROM dailycare_app;
GRANT SELECT ON deployment TO dailycare_app;
\set QUIET off

SET ROLE dailycare_app;

SELECT expect_rejected('the application scrubbing the database', format($$
  SELECT * FROM scrub_phi(%L)
$$, current_database()));

SELECT expect_rejected('the application rewriting a scrub rule', $$
  UPDATE scrub_rules SET strategy = 'keep', reason = 'no' WHERE column_name = 'note'
$$);

SELECT expect_rejected('the application relabelling the environment', $$
  UPDATE deployment SET environment = 'development'
$$);

SELECT expect('but it can read which environment it is running in',
  (SELECT environment = 'development' FROM deployment));

RESET ROLE;

\echo ''
\echo '── a sample of what is left'
SELECT r.display_name, r.admitted_on, c.care_date, c.mood, left(c.note, 42) AS note
FROM residents r LEFT JOIN care_days c ON c.resident_id = r.id
ORDER BY r.display_name, c.care_date;

\set QUIET on
SELECT checks_end();
DROP FUNCTION expect(text, boolean);
DROP FUNCTION expect_rejected(text, text);
\set QUIET off
