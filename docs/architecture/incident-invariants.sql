-- Incident and breach checks for incidents.sql
--
-- Run by verify.sh. See README.md for the manual sequence.
--
-- One incident, walked from discovery to notification, with the clock moved back at each
-- step rather than waited for. Two facilities: one whose agreement asks for thirty days
-- and one that takes the rule's sixty, so the difference between them is visible.

\set QUIET on
SET client_min_messages TO notice;
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
  EXCEPTION WHEN check_violation OR not_null_violation OR insufficient_privilege
               OR unique_violation THEN
    RAISE NOTICE 'PASS  refused: %', label; RETURN;
  END;
  RAISE NOTICE 'FAIL  ALLOWED, and should not have been: %', label;
END; $$ LANGUAGE plpgsql;

INSERT INTO facilities (id, name, timezone) VALUES
  ('f1000000-0000-0000-0000-000000000001', 'Cedar House', 'America/Chicago'),
  ('f2000000-0000-0000-0000-000000000002', 'Birch House', 'America/Chicago');
INSERT INTO facility_agreements (facility_id, executed_on, notification_contact,
                                 notification_days, counterparty) VALUES
  ('f1000000-0000-0000-0000-000000000001', current_date - 200, 'compliance@cedar.example',
   30, 'Cedar House Operating Company'),
  ('f2000000-0000-0000-0000-000000000002', current_date - 200, 'compliance@birch.example',
   60, 'Birch House Operating Company');
INSERT INTO residents (id, facility_id, display_name) VALUES
  ('e1000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000001', 'Cathy'),
  ('e2000000-0000-0000-0000-000000000002', 'f2000000-0000-0000-0000-000000000002', 'Mabel');
SELECT checks_end();
\set QUIET off


-- ── recording what happened ────────────────────────────────────────────────────

\echo ''
\echo '── the moment the paged engineer works out what the spike was'

\set QUIET on
INSERT INTO security_incidents (id, discovered_at, discovered_by, summary) VALUES
  ('11111111-0000-0000-0000-000000000001', now(), 'on-call engineer',
   'A session belonging to a caregiver read residents outside their assignments over eleven minutes. Session revoked; the account is suspended pending the workforce procedure.');
\set QUIET off

SELECT expect('an incident can be recorded before anybody knows what it is',
  (SELECT conclusion IS NULL FROM security_incidents
   WHERE id = '11111111-0000-0000-0000-000000000001'));

SELECT expect_refused('an incident that claims to carry the record it concerns', $$
  INSERT INTO security_incidents (discovered_at, discovered_by, summary, carries_phi)
  VALUES (now(), 'somebody', 'with the notes attached', true)
$$);


-- ── the four factors ───────────────────────────────────────────────────────────

\echo ''
\echo '── concluding it'

SELECT expect_refused('a conclusion of "not a breach" with none of the assessment', $$
  UPDATE security_incidents
  SET conclusion = 'not_a_breach', concluded_at = now(), concluded_by = 'somebody'
  WHERE id = '11111111-0000-0000-0000-000000000001'
$$);

\set QUIET on
UPDATE security_incidents SET
  f1_nature    = 'Names, dates and care notes for nine residents at one facility.',
  f2_recipient = 'A caregiver employed at the same facility, under the same workforce policy.',
  f3_acquired  = 'Read. Nothing was exported; the request log shows reads and no downloads.'
WHERE id = '11111111-0000-0000-0000-000000000001';
\set QUIET off

SELECT expect_refused('or with three of the four', $$
  UPDATE security_incidents
  SET conclusion = 'not_a_breach', concluded_at = now(), concluded_by = 'somebody'
  WHERE id = '11111111-0000-0000-0000-000000000001'
$$);

\set QUIET on
UPDATE security_incidents SET
  f4_mitigated = 'Session revoked within the hour; account suspended; the facility asked to confirm the person had no operational reason to look.'
WHERE id = '11111111-0000-0000-0000-000000000001';
\set QUIET off

SELECT expect_refused('a conclusion with nobody''s name against it', $$
  UPDATE security_incidents SET conclusion = 'breach', concluded_at = now()
  WHERE id = '11111111-0000-0000-0000-000000000001'
$$);

\set QUIET on
UPDATE security_incidents
SET conclusion = 'breach', concluded_at = now(), concluded_by = 'named security official'
WHERE id = '11111111-0000-0000-0000-000000000001';
\set QUIET off

SELECT expect('with all four and a name, the conclusion stands',
  (SELECT conclusion = 'breach' FROM security_incidents
   WHERE id = '11111111-0000-0000-0000-000000000001'));


-- ── the clock, which is the agreement's and not the rule's ─────────────────────

\echo ''
\echo '── whose deadline it is'

SELECT expect('the facility that asked for thirty days gets thirty',
  notification_deadline('11111111-0000-0000-0000-000000000001',
                        'f1000000-0000-0000-0000-000000000001')::date
  = (SELECT (discovered_at + interval '30 days')::date FROM security_incidents
     WHERE id = '11111111-0000-0000-0000-000000000001'));

SELECT expect('and the one that did not gets the rule''s sixty',
  notification_deadline('11111111-0000-0000-0000-000000000001',
                        'f2000000-0000-0000-0000-000000000002')::date
  = (SELECT (discovered_at + interval '60 days')::date FROM security_incidents
     WHERE id = '11111111-0000-0000-0000-000000000001'));

SELECT expect('nothing is overdue on the day it was discovered',
  (SELECT count(*) = 0 FROM notifications_overdue));

-- Thirty-one days later.
\set QUIET on
UPDATE security_incidents SET discovered_at = now() - interval '31 days'
WHERE id = '11111111-0000-0000-0000-000000000001';
\set QUIET off

SELECT expect('at thirty-one days the facility with the shorter window is overdue',
  (SELECT count(*) = 1 FROM notifications_overdue
   WHERE facility_id = 'f1000000-0000-0000-0000-000000000001'));

SELECT expect('and the other one is not',
  (SELECT count(*) = 0 FROM notifications_overdue
   WHERE facility_id = 'f2000000-0000-0000-0000-000000000002'));

-- Sixty-one.
\set QUIET on
UPDATE security_incidents SET discovered_at = now() - interval '61 days'
WHERE id = '11111111-0000-0000-0000-000000000001';
\set QUIET off

SELECT expect('at sixty-one both are',
  (SELECT count(*) = 2 FROM notifications_overdue));


-- ── telling them ───────────────────────────────────────────────────────────────

\echo ''
\echo '── the record that discharges the burden of proof'

\set QUIET on
INSERT INTO breach_notifications (incident_id, facility_id, notified_at, notified_whom,
                                  method, individuals, content_note) VALUES
  -- Discovered sixty-one days ago. Cedar's window was thirty, so its deadline passed
  -- thirty-one days ago and this went twenty-five days ago: late, and recorded as such.
  -- Birch's was sixty, so its deadline passed yesterday and the same message was early.
  ('11111111-0000-0000-0000-000000000001','f1000000-0000-0000-0000-000000000001',
   now() - interval '25 days', 'compliance@cedar.example', 'email, acknowledged',
   9, 'Covered 164.410(c): what happened, when, the categories involved, what we have done, and who to contact.'),
  ('11111111-0000-0000-0000-000000000001','f2000000-0000-0000-0000-000000000002',
   now() - interval '25 days', 'compliance@birch.example', 'email, acknowledged',
   0, 'Covered 164.410(c). No resident at this facility was involved; told because the assessment could not exclude it at the time.');
\set QUIET off

SELECT expect('once both are told, nothing is overdue',
  (SELECT count(*) = 0 FROM notifications_overdue));

SELECT expect('the one sent after its own deadline is kept on record rather than refused',
  (SELECT count(*) = 1 FROM notifications_late
   WHERE facility_id = 'f1000000-0000-0000-0000-000000000001'));

SELECT expect('and the one sent inside its window is not on that list',
  (SELECT count(*) = 0 FROM notifications_late
   WHERE facility_id = 'f2000000-0000-0000-0000-000000000002'));

SELECT expect('a facility cannot be told twice for the same incident',
  (SELECT count(*) = 2 FROM breach_notifications));

SELECT expect_refused('recording a second notification for the same facility', $$
  INSERT INTO breach_notifications (incident_id, facility_id, notified_at, notified_whom,
                                    method, individuals, content_note)
  VALUES ('11111111-0000-0000-0000-000000000001','f1000000-0000-0000-0000-000000000001',
          now(), 'again', 'email', 9, 'again')
$$);


-- ── an incident nobody came back to ────────────────────────────────────────────

\echo ''
\echo '── the one that goes quiet'

\set QUIET on
INSERT INTO security_incidents (id, discovered_at, discovered_by, summary) VALUES
  ('22222222-0000-0000-0000-000000000002', now() - interval '8 days', 'on-call engineer',
   'Audit trigger error rate above threshold for four minutes during a deploy.');
\set QUIET off

SELECT expect('an incident left unassessed for a week is reported',
  (SELECT count(*) = 1 FROM incidents_unassessed
   WHERE id = '22222222-0000-0000-0000-000000000002'));

SELECT expect('and one discovered this morning is not',
  (SELECT count(*) = 0 FROM incidents_unassessed
   WHERE id = '11111111-0000-0000-0000-000000000001'));

\echo ''
\echo '── the incident as it now reads'
SELECT left(summary, 58) AS summary, conclusion, concluded_by FROM security_incidents
ORDER BY discovered_at;

\set QUIET on
SELECT checks_end();
DROP FUNCTION expect(text, boolean);
DROP FUNCTION expect_refused(text, text);
\set QUIET off
