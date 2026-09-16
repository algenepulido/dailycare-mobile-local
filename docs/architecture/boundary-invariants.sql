-- Boundary checks for boundary.sql
--
-- Run by verify.sh. See README.md for the manual sequence.
--
-- The decision is that InkTree content flows into DailyCare and nothing flows back. These
-- are not about whether that is the right decision. They are about whether it survives
-- somebody building a feature next quarter who never read the sentence.

\set QUIET on
SET client_min_messages TO notice;

-- Lift FORCE for this suite so that it behaves the same run by a superuser and run by a
-- managed-instance owner. See checks-support.sql.
SELECT checks_begin();

CREATE OR REPLACE FUNCTION expect(label text, condition boolean) RETURNS void AS $$
BEGIN
  IF condition THEN RAISE NOTICE 'PASS  %', label;
  ELSE            RAISE NOTICE 'FAIL  %', label;
  END IF;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION expect_rows(label text, expected int, q text) RETURNS void AS $$
DECLARE n int;
BEGIN
  EXECUTE 'SELECT count(*) FROM (' || q || ') _' INTO n;
  IF n = expected THEN RAISE NOTICE 'PASS  %', label;
  ELSE RAISE NOTICE 'FAIL  % — expected %, saw %', label, expected, n;
  END IF;
END; $$ LANGUAGE plpgsql;

-- Breaks the boundary on purpose, asks whether the view noticed, rolls it back.
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

INSERT INTO facilities (id, name, timezone) VALUES
  ('f1000000-0000-0000-0000-000000000001', 'Cedar House', 'America/Chicago');
INSERT INTO users (id, email, display_name) VALUES
  ('a0000000-0000-0000-0000-00000000000a', 'maria@example.test', 'Maria'),
  ('c0000000-0000-0000-0000-00000000000c', 'anna@example.test',  'Anna');
INSERT INTO facility_members (id, facility_id, user_id, role, state) VALUES
  ('fa000000-0000-0000-0000-00000000000a', 'f1000000-0000-0000-0000-000000000001',
   'a0000000-0000-0000-0000-00000000000a', 'caregiver', 'active');
INSERT INTO residents (id, facility_id, display_name) VALUES
  ('e1000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000001', 'Cathy'),
  ('e2000000-0000-0000-0000-000000000002', 'f1000000-0000-0000-0000-000000000001', 'Robert');
INSERT INTO assignments (facility_id, resident_id, facility_member_id) VALUES
  ('f1000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001',
   'fa000000-0000-0000-0000-00000000000a');
INSERT INTO resident_contacts (facility_id, resident_id, user_id, relation, state, granted_at) VALUES
  ('f1000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001',
   'c0000000-0000-0000-0000-00000000000c', 'child', 'active', now());
INSERT INTO imported_content (id, facility_id, resident_id, external_ref, kind, title, body) VALUES
  ('c1000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000001',
   'e1000000-0000-0000-0000-000000000001', 'ink-1', 'story', 'The bakery',
   'She ran a bakery on Wilson Avenue for thirty years.'),
  ('c2000000-0000-0000-0000-000000000002', 'f1000000-0000-0000-0000-000000000001',
   'e2000000-0000-0000-0000-000000000002', 'ink-2', 'story', 'The allotment',
   'He grew leeks, and won things for them.');
INSERT INTO content_responses (facility_id, resident_id, content_id, response, note, observed_by) VALUES
  ('f1000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001',
   'c1000000-0000-0000-0000-000000000001', 'unsettled',
   'She asked for her mother afterwards.', 'a0000000-0000-0000-0000-00000000000a');

GRANT USAGE ON SCHEMA public TO dailycare_app;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO dailycare_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO dailycare_app;
REVOKE ALL ON boundary_channels, boundary_fields, integration_salts FROM dailycare_app;
GRANT SELECT ON boundary_channels TO dailycare_app;
\set QUIET off


-- ── which way things go ────────────────────────────────────────────────────────

\echo ''
\echo '── the channels'
SELECT id, direction, is_open FROM boundary_channels ORDER BY direction, id;

\echo ''
SELECT expect('there are inbound channels, which is the direction that was agreed',
  (SELECT count(*) >= 3 FROM boundary_channels WHERE direction = 'inbound'));

SELECT expect('nothing outbound is open',
  (SELECT count(*) = 0 FROM boundary_channels WHERE direction = 'outbound' AND is_open));

SELECT expect('every channel says what reversing it would require',
  (SELECT count(*) = 0 FROM boundary_channels WHERE reversal_requires = ''));

SELECT expect_rows('no channel exists that nobody listed the fields of', 0,
  'SELECT * FROM boundary_unspecified');

SELECT expect_rows('no open outbound channel carries anything classified', 0,
  'SELECT * FROM boundary_leaks');

SELECT expect_rows('and no outbound channel names a table of clinical observations', 0,
  'SELECT * FROM boundary_reminiscence_leak');

-- The uncomfortable answer, recorded rather than avoided.
\echo ''
\echo '── what is shut, and what opening it would cost'
SELECT channel, would_carry, left(reversal_requires, 90) AS reversal_requires
FROM boundary_blocked_channels;

SELECT expect('the one outbound channel anybody has thought of is shut and says why',
  (SELECT count(*) = 1 FROM boundary_blocked_channels
   WHERE channel = 'dailycare_activity_signal'
     AND would_carry LIKE '%identifying%'
     AND reversal_requires ILIKE '%agreement%'));

SELECT expect('and nothing has ever been written to the outbound table',
  (SELECT count(*) = 0 FROM outbound_signals));


-- ── the ways it gets reversed by accident ──────────────────────────────────────
--
-- Each of these is a plausible quarter's work by somebody who never read the decision.

\echo ''
\echo '── proving the boundary can fail'

SELECT expect_noticed('somebody opens the signal channel because a partner asked',
  $$UPDATE boundary_channels SET is_open = true WHERE id = 'dailycare_activity_signal'$$,
  'boundary_leaks');

SELECT expect_noticed('the reminiscence loop: send the response back so the next story is better',
  $$INSERT INTO boundary_fields (channel_id, table_name, column_name)
    VALUES ('dailycare_activity_signal', 'content_responses', 'response')$$,
  'boundary_reminiscence_leak');

SELECT expect_noticed('a resident name is added to the payload to make support easier',
  $$INSERT INTO boundary_fields (channel_id, table_name, column_name)
    VALUES ('dailycare_activity_signal', 'residents', 'display_name')$$,
  'boundary_reminiscence_leak');

SELECT expect_noticed('a new outbound channel with nobody having listed its fields',
  $$INSERT INTO boundary_channels (id, direction, carries, transport, is_open,
                                   reversal_requires, reviewed_on)
    VALUES ('analytics', 'outbound', 'usage', 'a webhook', true, 'nothing', current_date)$$,
  'boundary_unspecified');

SELECT expect('and the probes left the boundary as they found it',
  (SELECT count(*) = 0 FROM boundary_leaks)
  AND (SELECT count(*) = 0 FROM boundary_reminiscence_leak)
  AND (SELECT count(*) = 0 FROM boundary_unspecified)
  AND (SELECT count(*) = 4 FROM boundary_channels));


-- ── the likelier accident: the two databases become one ────────────────────────
--
-- The InkTree field guide says every one of their services reads and writes a single
-- Postgres instance directly, with no events in between. So there is no service-level
-- isolation over there to rely on: putting DailyCare data in that instance, or joining the
-- two with a foreign data wrapper, puts nine services and their vendors in scope at once.
-- It is also the cheapest thing anybody could propose, which is what makes it likely.

\echo ''
\echo '── the two databases have not been joined'

SELECT expect_rows('no foreign server, no foreign data wrapper, no dblink', 0,
  'SELECT * FROM boundary_database_joins');

SELECT expect_noticed('somebody installs dblink to make a report easier',
  $$CREATE EXTENSION dblink$$, 'boundary_database_joins');

SELECT expect_noticed('or a foreign data wrapper pointing at the platform database',
  $$CREATE FOREIGN DATA WRAPPER inktree_fdw$$, 'boundary_database_joins');

SELECT expect_rows('and the probes left none behind', 0,
  'SELECT * FROM boundary_database_joins');


-- ── the pseudonym ──────────────────────────────────────────────────────────────

\echo ''
\echo '── what a partner would receive instead of an identifier'

SELECT expect('the same resident gives the same subject every time',
  resident_pseudonym('e1000000-0000-0000-0000-000000000001','inktree')
  = resident_pseudonym('e1000000-0000-0000-0000-000000000001','inktree'));

SELECT expect('two residents do not collide',
  resident_pseudonym('e1000000-0000-0000-0000-000000000001','inktree')
  <> resident_pseudonym('e2000000-0000-0000-0000-000000000002','inktree'));

\set QUIET on
INSERT INTO integration_salts (integration, salt)
VALUES ('someone_else', encode(gen_random_bytes(32), 'hex'));
\set QUIET off

SELECT expect('and two partners are given different subjects for the same resident',
  resident_pseudonym('e1000000-0000-0000-0000-000000000001','inktree')
  <> resident_pseudonym('e1000000-0000-0000-0000-000000000001','someone_else'));

SELECT expect('the subject contains nothing of the uuid it came from',
  position(replace('e1000000-0000-0000-0000-000000000001','-','') in
           resident_pseudonym('e1000000-0000-0000-0000-000000000001','inktree')) = 0);

SELECT expect('the salt is classified as a secret, so it can never reach a log line',
  (SELECT count(*) = 1 FROM data_classification
   WHERE table_name = 'integration_salts' AND column_name = 'salt' AND class = 'secret')
  AND (SELECT count(*) = 1 FROM never_log WHERE field = 'salt'));

SELECT expect('a partner is unknown until somebody gives them a salt',
  resident_pseudonym('e1000000-0000-0000-0000-000000000001','never_heard_of_them') IS NULL);

\set QUIET on
DELETE FROM integration_salts WHERE integration = 'someone_else';
\set QUIET off


-- ── what arrives is DailyCare's from the moment it lands ───────────────────────

\echo ''
\echo '── imported content is a resident record, not a guest'

SET ROLE dailycare_app;
SELECT set_config('app.user_id', 'c0000000-0000-0000-0000-00000000000c', false) \gset
SELECT expect_rows('a daughter reads her mother''s story', 1, 'SELECT * FROM imported_content');
SELECT expect_rows('and not the other resident''s', 0,
  $$SELECT * FROM imported_content WHERE resident_id = 'e2000000-0000-0000-0000-000000000002'$$);
SELECT expect_rows('and not how her mother responded to it, which is a caregiver''s observation',
  0, 'SELECT * FROM content_responses');
RESET ROLE;

SET ROLE dailycare_app;
SELECT set_config('app.user_id', 'a0000000-0000-0000-0000-00000000000a', false) \gset
SELECT expect_rows('the caregiver assigned to her reads both the story and the response', 1,
  'SELECT * FROM content_responses');
SELECT expect_rows('but only for the resident assigned to her', 1, 'SELECT * FROM imported_content');
RESET ROLE;

SELECT set_config('app.user_id', '', false) \gset
SET ROLE dailycare_app;
SELECT expect_rows('an unidentified request reads no imported content', 0,
  'SELECT * FROM imported_content');
RESET ROLE;

SELECT expect('a write to imported content is audited like any other resident record',
  (SELECT count(*) >= 1 FROM audit_events WHERE action = 'imported_content.insert'));

SELECT expect('and so is a reminiscence response',
  (SELECT count(*) >= 1 FROM audit_events WHERE action = 'content_responses.insert'));

SELECT expect('neither appears in the audit trail in words',
  NOT EXISTS (SELECT 1 FROM audit_events
              WHERE to_jsonb(audit_events)::text ILIKE '%bakery%'
                 OR to_jsonb(audit_events)::text ILIKE '%asked for her mother%'));


-- ── and it leaves when the resident's record does ──────────────────────────────

\echo ''
\echo '── retention'

\set QUIET on
INSERT INTO retention_policies (facility_id, care_record_days, media_days, audit_days)
VALUES ('f1000000-0000-0000-0000-000000000001', 30, 7, 2190);
UPDATE residents SET departed_on = current_date - 400
WHERE id = 'e1000000-0000-0000-0000-000000000001';
\set QUIET off

SELECT expect('the run reports the imported content it destroyed',
  (SELECT count(*) = 2 FROM apply_retention('f1000000-0000-0000-0000-000000000001')
   WHERE what IN ('imported content', 'reminiscence responses')));

SELECT expect_rows('the story is gone from the table, not hidden', 0,
  $$SELECT * FROM imported_content WHERE resident_id = 'e1000000-0000-0000-0000-000000000001'$$);

SELECT expect_rows('so is the response', 0,
  $$SELECT * FROM content_responses WHERE resident_id = 'e1000000-0000-0000-0000-000000000001'$$);

SELECT expect_rows('and the resident with them', 0,
  $$SELECT * FROM residents WHERE id = 'e1000000-0000-0000-0000-000000000001'$$);

SELECT expect_rows('the other resident''s story is untouched', 1,
  $$SELECT * FROM imported_content WHERE resident_id = 'e2000000-0000-0000-0000-000000000002'$$);

\set QUIET on
SELECT checks_end();
DROP FUNCTION expect(text, boolean);
DROP FUNCTION expect_rows(text, int, text);
DROP FUNCTION expect_noticed(text, text, text);
\set QUIET off
