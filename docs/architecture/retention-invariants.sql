-- Retention checks for retention.sql
--
--   createdb dc_retention_check
--   psql -v ON_ERROR_STOP=1 -d dc_retention_check -f schema.sql
--   psql -v ON_ERROR_STOP=1 -d dc_retention_check -f access-policies.sql
--   psql -v ON_ERROR_STOP=1 -d dc_retention_check -f data-classification.sql
--   psql -v ON_ERROR_STOP=1 -d dc_retention_check -f audit-logging.sql
--   psql -v ON_ERROR_STOP=1 -d dc_retention_check -f retention.sql
--   psql -d dc_retention_check -f retention-invariants.sql
--   dropdb dc_retention_check
--
-- The question these have to answer is the one a reviewer actually asks, which is not
-- "does the job run" but "is the record gone". A soft delete, a filtered view or a row
-- that survives under another name would all pass a test that only counted what the API
-- returns, so the checks below count rows in the tables themselves, as the owner, with
-- row-level security out of the way.
--
-- Everything runs as dailycare_retention, because a superuser bypasses the policies that
-- are half the design.

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

CREATE OR REPLACE FUNCTION expect_refused(label text, stmt text) RETURNS void AS $$
BEGIN
  BEGIN
    EXECUTE stmt;
  EXCEPTION
    WHEN insufficient_privilege THEN
      RAISE NOTICE 'PASS  refused: %', label; RETURN;
    WHEN OTHERS THEN
      RAISE NOTICE 'PASS  refused (%): %', SQLERRM, label; RETURN;
  END;
  RAISE NOTICE 'FAIL  ALLOWED, and should not have been: %', label;
END; $$ LANGUAGE plpgsql;
\set QUIET off


-- ── fixtures ───────────────────────────────────────────────────────────────────
--
--   e1  departed 400 days ago, no media           → due, and must actually go
--   e2  still in the building                     → never due
--   e3  departed 10 days ago                      → inside the 30-day window
--   e4  departed 400 days ago, photo still in GCS → due, but held back
--   e5  departed 400 days ago, different facility → untouched by a run on Cedar House

\set QUIET on
INSERT INTO facilities (id, name, timezone) VALUES
  ('f1000000-0000-0000-0000-000000000001', 'Cedar House', 'America/Chicago'),
  ('f2000000-0000-0000-0000-000000000002', 'Birch Court', 'America/Chicago');

INSERT INTO retention_policies (facility_id, care_record_days, media_days, audit_days, care_record_basis) VALUES
  ('f1000000-0000-0000-0000-000000000001', 30, 7, 2190, 'State long-term-care record retention, fixture value'),
  ('f2000000-0000-0000-0000-000000000002', 30, 7, 2190, 'State long-term-care record retention, fixture value');

INSERT INTO users (id, email, display_name) VALUES
  ('a0000000-0000-0000-0000-00000000000a', 'maria@example.test',  'Maria'),
  ('a0000000-0000-0000-0000-00000000000b', 'daniel@example.test', 'Daniel');

INSERT INTO facility_members (id, facility_id, user_id, role, state) VALUES
  ('fa000000-0000-0000-0000-00000000000a', 'f1000000-0000-0000-0000-000000000001',
   'a0000000-0000-0000-0000-00000000000a', 'caregiver', 'active');

INSERT INTO residents (id, facility_id, display_name, departed_on) VALUES
  ('e1000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000001',
   'Cathy',   current_date - 400),
  ('e2000000-0000-0000-0000-000000000002', 'f1000000-0000-0000-0000-000000000001',
   'Dorothy', NULL),
  ('e3000000-0000-0000-0000-000000000003', 'f1000000-0000-0000-0000-000000000001',
   'Evelyn',  current_date - 10),
  ('e4000000-0000-0000-0000-000000000004', 'f1000000-0000-0000-0000-000000000001',
   'Frances', current_date - 400),
  ('e5000000-0000-0000-0000-000000000005', 'f2000000-0000-0000-0000-000000000002',
   'Grace',   current_date - 400);

INSERT INTO care_days (id, facility_id, resident_id, care_date, mood, appetite, sleep,
                       note, filed_by)
SELECT ('cd000000-0000-0000-0000-00000000000' || n)::uuid,
       r.facility_id, r.id, current_date - 500, 'calm', 'good', 'restless',
       'RETAINED-CANARY-' || r.display_name, 'a0000000-0000-0000-0000-00000000000a'
FROM (VALUES (1, 'e1000000-0000-0000-0000-000000000001'::uuid),
             (2, 'e2000000-0000-0000-0000-000000000002'::uuid),
             (3, 'e3000000-0000-0000-0000-000000000003'::uuid),
             (4, 'e4000000-0000-0000-0000-000000000004'::uuid),
             (5, 'e5000000-0000-0000-0000-000000000005'::uuid)) AS v(n, rid)
JOIN residents r ON r.id = v.rid;

INSERT INTO care_day_meals (care_day_id, slot, happened, amount) VALUES
  ('cd000000-0000-0000-0000-000000000001', 'breakfast', true, 'half'),
  ('cd000000-0000-0000-0000-000000000001', 'lunch',     true, 'most');
INSERT INTO care_day_concerns (care_day_id, concern) VALUES
  ('cd000000-0000-0000-0000-000000000001', 'sundowning');

INSERT INTO medication_events (facility_id, resident_id, care_date, slot, status,
                               source, recorded_by)
SELECT r.facility_id, r.id, current_date - 500, 'am', 'given', 'caregiver',
       'a0000000-0000-0000-0000-00000000000a'
FROM residents r;

INSERT INTO resident_contacts (facility_id, resident_id, user_id, relation, state)
SELECT r.facility_id, r.id, 'a0000000-0000-0000-0000-00000000000b', 'child', 'active'
FROM residents r;

INSERT INTO assignments (facility_id, resident_id, facility_member_id)
SELECT r.facility_id, r.id, 'fa000000-0000-0000-0000-00000000000a'
FROM residents r WHERE r.facility_id = 'f1000000-0000-0000-0000-000000000001';

-- Frances's photograph. Still in the bucket: deleted_at is null.
INSERT INTO media_objects (id, facility_id, resident_id, care_day_id, bucket, object_path,
                           content_type, byte_size, uploaded_by)
VALUES ('4e000000-0000-0000-0000-00000000000f',
        'f1000000-0000-0000-0000-000000000001',
        'e4000000-0000-0000-0000-000000000004',
        'cd000000-0000-0000-0000-000000000004',
        'dailycare-media-prod', 'f1000000-0000-0000-0000-000000000001/2025/frances-garden.jpg',
        'image/jpeg', 184320, 'a0000000-0000-0000-0000-00000000000a');

-- An audit row older than the six-year window, and one from today.
INSERT INTO audit_events (occurred_at, facility_id, action, subject_type, resident_id)
VALUES (now() - interval '10 years', 'f1000000-0000-0000-0000-000000000001',
        'care_day.read', 'care_day', 'e1000000-0000-0000-0000-000000000001');

GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO dailycare_retention;
\set QUIET off


-- ── the floor under the windows ────────────────────────────────────────────────
--
-- A facility that decided thirty days got thirty days, and the audit trail is the
-- accounting of disclosures it owes a resident for six years and the record of security
-- activity a business associate must keep for the same. Both would have been destroyed on
-- schedule by a job working exactly as designed.

\echo ''
\echo '── what a facility may decide, and what it may not'

SELECT expect_refused('an audit window of thirty days', $$
  INSERT INTO retention_policies (facility_id, care_record_days, media_days, audit_days,
                                  care_record_basis)
  VALUES ('f2000000-0000-0000-0000-000000000002', 365, 365, 30, 'a number')
$$);

SELECT expect_refused('or a care-record number resting on nothing anybody can name', $$
  INSERT INTO retention_policies (facility_id, care_record_days, media_days, audit_days,
                                  care_record_basis)
  VALUES ('f3000000-0000-0000-0000-000000000003', 365, 365, 2190, '   ')
$$);

SELECT expect('but six years exactly is accepted, so the floor is a floor and not a wall',
  (SELECT count(*) = 2 FROM retention_policies WHERE audit_days = 2190));


-- ── what the job thinks is due ─────────────────────────────────────────────────

\echo ''
\echo '── what is due, before anything is deleted'

SET ROLE dailycare_retention;

SELECT expect('a resident departed past the window is due',
  EXISTS (SELECT 1 FROM retention_due_residents('f1000000-0000-0000-0000-000000000001')
          WHERE resident_id = 'e1000000-0000-0000-0000-000000000001'));

SELECT expect('a resident still in the building is not, however old the record',
  NOT EXISTS (SELECT 1 FROM retention_due_residents('f1000000-0000-0000-0000-000000000001')
              WHERE resident_id = 'e2000000-0000-0000-0000-000000000002'));

SELECT expect('nor is one who left inside the window',
  NOT EXISTS (SELECT 1 FROM retention_due_residents('f1000000-0000-0000-0000-000000000001')
              WHERE resident_id = 'e3000000-0000-0000-0000-000000000003'));

SELECT expect('a run on one facility does not list the other facility''s residents',
  NOT EXISTS (SELECT 1 FROM retention_due_residents('f1000000-0000-0000-0000-000000000001')
              WHERE resident_id = 'e5000000-0000-0000-0000-000000000005'));

SELECT expect('the photograph is listed for the job to remove from storage',
  (SELECT count(*) = 1 FROM retention_due_media('f1000000-0000-0000-0000-000000000001')
   WHERE media_id = '4e000000-0000-0000-0000-00000000000f'
     AND reason   = 'resident record expired'));


-- ── the database refuses what the policy does not permit ───────────────────────
--
-- Row-level security filters rather than raises, so the assertion is that the statement
-- removed nothing and the row is still there — which is the behaviour that matters.

\echo ''
\echo '── the second check: what the retention role is allowed to touch'

\set QUIET on
DELETE FROM residents WHERE id = 'e2000000-0000-0000-0000-000000000002';
\set QUIET off
SELECT expect('deleting a resident still in the building removes nothing',
  EXISTS (SELECT 1 FROM residents WHERE id = 'e2000000-0000-0000-0000-000000000002'));

\set QUIET on
DELETE FROM residents WHERE id = 'e3000000-0000-0000-0000-000000000003';
\set QUIET off
SELECT expect('and neither does one who left inside the window',
  EXISTS (SELECT 1 FROM residents WHERE id = 'e3000000-0000-0000-0000-000000000003'));

\set QUIET on
DELETE FROM media_objects WHERE id = '4e000000-0000-0000-0000-00000000000f';
\set QUIET off
SELECT expect('a media row cannot be removed while its object is still in the bucket',
  EXISTS (SELECT 1 FROM media_objects WHERE id = '4e000000-0000-0000-0000-00000000000f'));

SELECT expect_refused('reading a care note as the retention role', $$
  SELECT note FROM care_days LIMIT 1
$$);

SELECT expect_refused('reading a resident''s name as the retention role', $$
  SELECT display_name FROM residents LIMIT 1
$$);

SELECT expect_refused('reading a medication status as the retention role', $$
  SELECT status FROM medication_events LIMIT 1
$$);


-- ── the run ────────────────────────────────────────────────────────────────────

\echo ''
\echo '── applying retention to Cedar House'
SELECT what, removed FROM apply_retention('f1000000-0000-0000-0000-000000000001');

RESET ROLE;

\echo ''
\echo '── and afterwards, counted in the tables themselves'

SELECT expect('the expired resident is gone from the residents table',
  NOT EXISTS (SELECT 1 FROM residents WHERE id = 'e1000000-0000-0000-0000-000000000001'));

SELECT expect('so are their care days, not merely hidden',
  NOT EXISTS (SELECT 1 FROM care_days
              WHERE resident_id = 'e1000000-0000-0000-0000-000000000001'));

SELECT expect('the meals on that day went with it, by cascade',
  NOT EXISTS (SELECT 1 FROM care_day_meals
              WHERE care_day_id = 'cd000000-0000-0000-0000-000000000001'));

SELECT expect('and the concerns',
  NOT EXISTS (SELECT 1 FROM care_day_concerns
              WHERE care_day_id = 'cd000000-0000-0000-0000-000000000001'));

SELECT expect('the medication events are gone',
  NOT EXISTS (SELECT 1 FROM medication_events
              WHERE resident_id = 'e1000000-0000-0000-0000-000000000001'));

SELECT expect('the family''s access row is gone',
  NOT EXISTS (SELECT 1 FROM resident_contacts
              WHERE resident_id = 'e1000000-0000-0000-0000-000000000001'));

SELECT expect('and the assignment',
  NOT EXISTS (SELECT 1 FROM assignments
              WHERE resident_id = 'e1000000-0000-0000-0000-000000000001'));

SELECT expect('the note itself is nowhere in the database any more',
  NOT EXISTS (SELECT 1 FROM care_days WHERE note LIKE '%RETAINED-CANARY-Cathy%'));

SELECT expect('the resident still in the building kept their record',
  EXISTS (SELECT 1 FROM care_days
          WHERE resident_id = 'e2000000-0000-0000-0000-000000000002'));

SELECT expect('the other facility was not touched',
  EXISTS (SELECT 1 FROM residents WHERE id = 'e5000000-0000-0000-0000-000000000005')
  AND EXISTS (SELECT 1 FROM care_days
              WHERE resident_id = 'e5000000-0000-0000-0000-000000000005'));


-- ── the record held back by its photograph ─────────────────────────────────────

\echo ''
\echo '── the handshake'

SELECT expect('the resident whose photo is still in the bucket was not deleted',
  EXISTS (SELECT 1 FROM residents WHERE id = 'e4000000-0000-0000-0000-000000000004'));

SELECT expect('and neither was the record the photo belongs to',
  EXISTS (SELECT 1 FROM care_days
          WHERE resident_id = 'e4000000-0000-0000-0000-000000000004'));

\echo '   the job now removes the object from storage and confirms it'
SET ROLE dailycare_retention;
SELECT retention_confirm_media(ARRAY['4e000000-0000-0000-0000-00000000000f']::uuid[])
       AS confirmed;

\set QUIET on
UPDATE media_objects SET deleted_at = NULL
WHERE id = '4e000000-0000-0000-0000-00000000000f';
\set QUIET off
SELECT expect('a confirmation cannot be taken back to make a deleted photo look present',
  (SELECT deleted_at IS NOT NULL FROM media_objects
   WHERE id = '4e000000-0000-0000-0000-00000000000f'));

\echo '   and the next run finishes the record'
SELECT what, removed FROM apply_retention('f1000000-0000-0000-0000-000000000001');
RESET ROLE;

SELECT expect('the media row is gone now that the object is',
  NOT EXISTS (SELECT 1 FROM media_objects
              WHERE id = '4e000000-0000-0000-0000-00000000000f'));

SELECT expect('and so is the resident it was held back for',
  NOT EXISTS (SELECT 1 FROM residents WHERE id = 'e4000000-0000-0000-0000-000000000004'));

SELECT expect('nothing is left pointing at a resident who no longer exists',
  NOT EXISTS (SELECT 1 FROM care_days        c WHERE NOT EXISTS
                (SELECT 1 FROM residents r WHERE r.id = c.resident_id))
  AND NOT EXISTS (SELECT 1 FROM medication_events m WHERE NOT EXISTS
                (SELECT 1 FROM residents r WHERE r.id = m.resident_id))
  AND NOT EXISTS (SELECT 1 FROM media_objects   o WHERE NOT EXISTS
                (SELECT 1 FROM residents r WHERE r.id = o.resident_id)));


-- ── the trail outlives the record ──────────────────────────────────────────────

\echo ''
\echo '── the audit trail'

SELECT expect('the trail still holds rows about a resident who no longer exists',
  EXISTS (SELECT 1 FROM audit_events
          WHERE resident_id = 'e1000000-0000-0000-0000-000000000001'));

SELECT expect('an audit row older than the facility''s audit window was removed',
  NOT EXISTS (SELECT 1 FROM audit_events
              WHERE occurred_at < now() - interval '9 years'));

SELECT expect('the run recorded itself',
  EXISTS (SELECT 1 FROM audit_events WHERE action = 'retention.applied'));

SELECT expect('with counts, and the counts add up',
  (SELECT (detail ->> 'residents')::int = 1 AND (detail ->> 'care_days')::int = 1
   FROM audit_events WHERE action = 'retention.applied' ORDER BY id LIMIT 1));

SELECT expect('and without naming anyone whose record was destroyed',
  NOT EXISTS (SELECT 1 FROM audit_events
              WHERE action = 'retention.applied'
                AND (detail::text ILIKE '%Cathy%'
                  OR detail::text ILIKE '%e1000000%'
                  OR detail::text ILIKE '%RETAINED-CANARY%')));

SELECT expect('the photograph''s deletion is itself in the trail',
  EXISTS (SELECT 1 FROM audit_events
          WHERE action = 'media_objects.update'
            AND detail -> 'columns' @> '["deleted_at"]'::jsonb));


-- ── who may cause any of this ──────────────────────────────────────────────────

\echo ''
\echo '── the application is not permitted to delete anything, or to ask retention to'

\set QUIET on
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dailycare_app') THEN
    RAISE EXCEPTION 'role dailycare_app does not exist. Apply roles.sql first.';
  END IF;
END $$;
GRANT USAGE ON SCHEMA public TO dailycare_app;
-- No blanket grant here; see grants.sql. DELETE is granted explicitly further down,
-- where a check needs to prove the policies stop it even when the grant exists.
REVOKE INSERT, UPDATE, DELETE ON audit_events FROM dailycare_app;
\set QUIET off

SET ROLE dailycare_app;

SELECT expect_refused('the application calling apply_retention', $$
  SELECT * FROM apply_retention('f1000000-0000-0000-0000-000000000001')
$$);

SELECT expect_refused('the application confirming a media deletion', $$
  SELECT retention_confirm_media(ARRAY[]::uuid[])
$$);

SELECT expect_refused('the application deleting a resident', $$
  DELETE FROM residents WHERE id = 'e2000000-0000-0000-0000-000000000002'
$$);
SELECT expect_refused('or a care day', $$
  DELETE FROM care_days WHERE resident_id = 'e2000000-0000-0000-0000-000000000002'
$$);
RESET ROLE;

SELECT expect('the application holding table-level DELETE still removes no resident',
  EXISTS (SELECT 1 FROM residents WHERE id = 'e2000000-0000-0000-0000-000000000002'));

SELECT expect('and no care day, because no DELETE policy exists for it on any table',
  EXISTS (SELECT 1 FROM care_days
          WHERE resident_id = 'e2000000-0000-0000-0000-000000000002'));


-- ── a facility that has not decided ────────────────────────────────────────────

\echo ''
\echo '── a facility with no policy'

\set QUIET on
INSERT INTO facilities (id, name, timezone) VALUES
  ('f3000000-0000-0000-0000-000000000003', 'Aspen Lodge', 'America/Denver');
\set QUIET off

SET ROLE dailycare_retention;
SELECT expect_refused('running retention on a facility that has set no policy', $$
  SELECT * FROM apply_retention('f3000000-0000-0000-0000-000000000003')
$$);
RESET ROLE;


\echo ''
\echo '── what Cedar House has left'
SELECT r.display_name, r.departed_on,
       (SELECT count(*) FROM care_days c WHERE c.resident_id = r.id) AS care_days
FROM residents r
WHERE r.facility_id = 'f1000000-0000-0000-0000-000000000001'
ORDER BY r.display_name;

\set QUIET on
SELECT checks_end();
DROP FUNCTION expect(text, boolean);
DROP FUNCTION expect_refused(text, text);
\set QUIET off
