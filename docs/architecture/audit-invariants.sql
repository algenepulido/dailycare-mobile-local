-- Audit checks for audit-logging.sql
--
--   createdb dc_audit_check
--   psql -v ON_ERROR_STOP=1 -d dc_audit_check -f schema.sql
--   psql -v ON_ERROR_STOP=1 -d dc_audit_check -f access-policies.sql
--   psql -v ON_ERROR_STOP=1 -d dc_audit_check -f data-classification.sql
--   psql -v ON_ERROR_STOP=1 -d dc_audit_check -f audit-logging.sql
--   psql -d dc_audit_check -f audit-invariants.sql
--   dropdb dc_audit_check
--
-- The check that matters most is the canary: a care note is written containing a string
-- that exists nowhere else, and then every column of every audit row is searched for it.
-- An audit trail that quotes the record it protects has quietly become a second copy of
-- that record, usually with a longer retention and a weaker one.

\set QUIET on
SET client_min_messages TO notice;
-- Lift FORCE for this suite so that it behaves the same run by a superuser and run by a
-- managed-instance owner. See checks-support.sql: the policies stay in force, and every
-- check that tests one does it by becoming the role it is about.
SELECT checks_begin();

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dailycare_app') THEN
    RAISE EXCEPTION 'role dailycare_app does not exist. Apply roles.sql first.';
  END IF;
END $$;

GRANT USAGE ON SCHEMA public TO dailycare_app;
-- No blanket grant here. grants.sql is the baseline and these checks run against it,
-- so what the application may touch is the same in a suite as in production.
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO dailycare_app;
REVOKE INSERT, UPDATE, DELETE ON audit_events FROM dailycare_app;
GRANT EXECUTE ON FUNCTION audit_read(uuid, text, uuid) TO dailycare_app;

CREATE OR REPLACE FUNCTION expect(label text, condition boolean) RETURNS void AS $$
BEGIN
  IF condition THEN RAISE NOTICE 'PASS  %', label;
  ELSE            RAISE NOTICE 'FAIL  %', label;
  END IF;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION expect_refused(label text, stmt text) RETURNS void AS $$
BEGIN
  BEGIN
    EXECUTE stmt;
  -- The codes that mean the database refused. Not WHEN OTHERS: a typo in a probe should
  -- fail loudly rather than be reported as the refusal it was testing for.
  EXCEPTION WHEN insufficient_privilege OR check_violation THEN
    RAISE NOTICE 'PASS  refused: %', label;
    RETURN;
  END;
  RAISE NOTICE 'FAIL  ALLOWED, and should not have been: %', label;
END; $$ LANGUAGE plpgsql;
\set QUIET off


-- ── fixtures ───────────────────────────────────────────────────────────────────

INSERT INTO facilities (id, name, timezone) VALUES
  ('f1000000-0000-0000-0000-000000000001', 'Cedar House', 'America/Chicago');

INSERT INTO users (id, email, display_name) VALUES
  ('a0000000-0000-0000-0000-00000000000a', 'maria@example.test', 'Maria');

INSERT INTO facility_members (id, facility_id, user_id, role, state) VALUES
  ('fa000000-0000-0000-0000-00000000000a', 'f1000000-0000-0000-0000-000000000001',
   'a0000000-0000-0000-0000-00000000000a', 'caregiver', 'active');

SELECT set_config('app.user_id',    'a0000000-0000-0000-0000-00000000000a', false);
SELECT set_config('app.role',       'caregiver', false);
SELECT set_config('app.request_id', 'req-0001',  false);


-- ── a write produces a row without anyone remembering to ask ───────────────────

\echo ''
\echo '── writes are recorded by the database, not by the handler'

INSERT INTO residents (id, facility_id, display_name) VALUES
  ('e1000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000001', 'Cathy');

-- Maria is assigned to Cathy. Without this she is a caregiver at the building who is not
-- responsible for this resident, and audit_read() now refuses to record a read the access
-- model would not permit - which is the point of the guard, and was the bug before it.
INSERT INTO assignments (facility_id, resident_id, facility_member_id) VALUES
  ('f1000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001',
   'fa000000-0000-0000-0000-00000000000a');

SELECT expect('creating a resident wrote an audit row',
  (SELECT count(*) = 1 FROM audit_events WHERE action = 'residents.insert'));

SELECT expect('and it carries the actor, the role and the request',
  (SELECT actor_user_id = 'a0000000-0000-0000-0000-00000000000a'
      AND actor_role    = 'caregiver'
      AND request_id    = 'req-0001'
   FROM audit_events WHERE action = 'residents.insert'));

SELECT expect('and it names the resident it concerns',
  (SELECT resident_id = 'e1000000-0000-0000-0000-000000000001'
   FROM audit_events WHERE action = 'residents.insert'));


-- ── the canary ─────────────────────────────────────────────────────────────────

\echo ''
\echo '── the care record must not leak into the trail that protects it'

INSERT INTO care_days (id, facility_id, resident_id, care_date, mood, appetite, sleep, note, filed_by)
VALUES ('cd000000-0000-0000-0000-000000000001',
        'f1000000-0000-0000-0000-000000000001',
        'e1000000-0000-0000-0000-000000000001',
        '2026-09-14', 'agitated', 'refused', 'didnt_sleep',
        'CANARY-7f3a91-she-was-frightened-again-tonight',
        'a0000000-0000-0000-0000-00000000000a');

-- An amendment, in the shape the model now enforces: the correction is a new row and the
-- original is stamped. This check used to rewrite the note in place, which the model
-- described as impossible and the database allowed - so the check was demonstrating the
-- defect rather than the guarantee.
UPDATE care_days SET superseded_at = now()
WHERE id = 'cd000000-0000-0000-0000-000000000001';

INSERT INTO care_days (id, facility_id, resident_id, care_date, mood, appetite, sleep, note,
                       filed_by, amends_id)
VALUES ('cd000000-0000-0000-0000-000000000002',
        'f1000000-0000-0000-0000-000000000001',
        'e1000000-0000-0000-0000-000000000001',
        '2026-09-14', 'anxious', 'poor', 'up_a_lot',
        'CANARY-7f3a91-amended',
        'a0000000-0000-0000-0000-00000000000a',
        'cd000000-0000-0000-0000-000000000001');


SELECT expect('the note never appears anywhere in the audit trail',
  NOT EXISTS (
    SELECT 1 FROM audit_events
    WHERE to_jsonb(audit_events)::text ILIKE '%CANARY-7f3a91%'
  ));

SELECT expect('nor does a clinical value the caregiver recorded',
  NOT EXISTS (
    SELECT 1 FROM audit_events
    WHERE detail::text ILIKE '%agitated%'
       OR detail::text ILIKE '%refused%'
       OR detail::text ILIKE '%didnt_sleep%'
  ));

SELECT expect('but the trail does say which column retiring a day touched, and only that',
  (SELECT detail -> 'columns' = '["superseded_at"]'::jsonb
   FROM audit_events WHERE action = 'care_days.update' ORDER BY id DESC LIMIT 1));

SELECT expect('and the amendment itself is an insert, so both versions are attributable',
  (SELECT count(*) = 2 FROM audit_events WHERE action = 'care_days.insert'));

SELECT expect('the original is still readable, which is the point of amending by adding',
  (SELECT count(*) = 1 FROM care_days
   WHERE id = 'cd000000-0000-0000-0000-000000000001'
     AND note = 'CANARY-7f3a91-she-was-frightened-again-tonight'
     AND superseded_at IS NOT NULL));


-- ── an update that changed nothing ─────────────────────────────────────────────

\echo ''
\echo '── noise'

SELECT count(*) AS before_noop FROM audit_events \gset
UPDATE care_days SET superseded_at = superseded_at
WHERE id = 'cd000000-0000-0000-0000-000000000001';

SELECT expect('an update that changed nothing wrote nothing',
  (SELECT count(*) FROM audit_events) = :before_noop);


-- ── reads ──────────────────────────────────────────────────────────────────────

\echo ''
\echo '── reads, which the application has to declare'

SELECT audit_read('e1000000-0000-0000-0000-000000000001', 'care_days',
                  'cd000000-0000-0000-0000-000000000001');

SELECT expect('a declared read is recorded against the resident',
  (SELECT count(*) = 1 FROM audit_events
   WHERE action = 'care_days.read'
     AND resident_id = 'e1000000-0000-0000-0000-000000000001'));

-- The other half, and the reason this function needed a guard at all: it runs as the
-- definer and is granted to the application, so without these it was a way to write an
-- audit row by hand - the one thing the revoked privileges below are there to prevent.
\set QUIET on
INSERT INTO facilities (id, name, timezone) VALUES
  ('f2000000-0000-0000-0000-000000000002', 'Birch House', 'America/Chicago');
INSERT INTO residents (id, facility_id, display_name) VALUES
  ('e9000000-0000-0000-0000-000000000009', 'f2000000-0000-0000-0000-000000000002', 'Mabel');
\set QUIET off

SELECT expect_refused('recording a read of a resident this session cannot see', $$
  SELECT audit_read('e9000000-0000-0000-0000-000000000009', 'care_days')
$$);

SELECT expect_refused('or putting free text where a table name goes', $$
  SELECT audit_read('e1000000-0000-0000-0000-000000000001', 'PHI_CANARY_in_subject')
$$);

-- Creating Mabel wrote an audit row about Mabel, by trigger, which is correct. What must
-- not exist is a read recorded by a session that could not have read her.
SELECT expect('so no read reached the trail by either route',
  (SELECT count(*) = 0 FROM audit_events
   WHERE action LIKE '%.read'
     AND (resident_id = 'e9000000-0000-0000-0000-000000000009' OR action ILIKE '%CANARY%')));


-- ── coverage ───────────────────────────────────────────────────────────────────

\echo ''
\echo '── every table holding PHI has a trigger'

SELECT expect('no PHI-bearing table is missing an audit trigger',
  (SELECT count(*) = 0 FROM audit_gaps));

SELECT expect('and the coverage view is not empty, which would make the line above meaningless',
  (SELECT count(*) > 0 FROM audit_coverage));

\echo '   tables covered:'
SELECT table_name, phi_columns, has_audit_trigger FROM audit_coverage;


-- ── the application cannot write its own history ───────────────────────────────

\echo ''
\echo '── what the application is not permitted to do'
SET ROLE dailycare_app;

SELECT expect_refused('inserting an audit row by hand', $$
  INSERT INTO audit_events (action, subject_type) VALUES ('nothing.happened', 'resident')
$$);

SELECT expect_refused('editing an audit row', $$
  UPDATE audit_events SET action = 'something.else' WHERE action = 'residents.insert'
$$);

SELECT expect_refused('deleting an audit row', $$
  DELETE FROM audit_events WHERE action = 'residents.insert'
$$);

RESET ROLE;

\echo ''
\echo '── the trail as it stands'
SELECT action, subject_type, coalesce(detail -> 'columns', '[]'::jsonb) AS columns_changed
FROM audit_events ORDER BY id;

\set QUIET on
SELECT checks_end();
DROP FUNCTION expect(text, boolean);
DROP FUNCTION expect_refused(text, text);
\set QUIET off
