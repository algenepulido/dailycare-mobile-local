-- Logging and notification checks for phi-safe-logging.sql
--
-- Run by verify.sh. See README.md for the manual sequence.
--
-- The guard here is a naming guard: it catches a log line with a field called note or
-- display_name, not a log line containing the word Cathy. That distinction is the honest
-- limit of what a database function can do, and it is the right place to draw the line -
-- the mistake this is built for is a developer serialising a row into a log, and a
-- serialised row carries its column names with it.

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

CREATE OR REPLACE FUNCTION expect_rejected(label text, stmt text) RETURNS void AS $$
BEGIN
  BEGIN
    EXECUTE stmt;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'PASS  refused: %', label; RETURN;
  END;
  RAISE NOTICE 'FAIL  ALLOWED, and should not have been: %', label;
END; $$ LANGUAGE plpgsql;
\set QUIET off


-- ── the list is generated, not maintained ──────────────────────────────────────

\echo ''
\echo '── what a log line may not contain'

SELECT expect('the list is not empty, which would make every check below pass for nothing',
  (SELECT count(*) > 20 FROM never_log));

SELECT expect('it holds the fields that would actually hurt',
  (SELECT count(*) = 5 FROM never_log
   WHERE field IN ('note', 'display_name', 'email', 'password_hash', 'object_path')));

SELECT expect('and not the identifiers, because a uuid is what makes a log line useful',
  (SELECT count(*) = 0 FROM never_log
   WHERE field IN ('id', 'resident_id', 'facility_id', 'user_id', 'care_day_id')));

-- The reason it is a view over the classification rather than a list somebody keeps.
\set QUIET on
ALTER TABLE care_days ADD COLUMN behaviour_note text;
INSERT INTO data_classification (table_name, column_name, class, note)
VALUES ('care_days','behaviour_note','phi','Added by a later migration.');
\set QUIET off

SELECT expect('a PHI column added in a later migration joins the list by itself',
  (SELECT count(*) = 1 FROM never_log WHERE field = 'behaviour_note'));

\set QUIET on
DELETE FROM data_classification WHERE column_name = 'behaviour_note';
ALTER TABLE care_days DROP COLUMN behaviour_note;
\set QUIET off


-- ── and the classification it is generated from is complete ────────────────────
--
-- never_log is only as good as the classification underneath it, and the completeness of
-- that classification was a line in a README telling somebody to run a query. It was wrong
-- for twelve tables and ninety-seven columns before anybody ran it, which is the argument
-- for it being a check rather than an instruction.

\echo ''
\echo '── the classification underneath it'

SELECT expect('every column in the schema has been classified',
  (SELECT count(*) = 0 FROM unclassified_columns));

SELECT expect('and the inventory is not empty, which would make that cheap',
  (SELECT count(*) > 100 FROM data_classification));

\set QUIET on
ALTER TABLE facilities ADD COLUMN nobody_thought_about_this text;
\set QUIET off

SELECT expect('a column added without a classification is reported rather than assumed harmless',
  (SELECT count(*) = 1 FROM unclassified_columns
   WHERE table_name = 'facilities' AND column_name = 'nobody_thought_about_this'));

\set QUIET on
ALTER TABLE facilities DROP COLUMN nobody_thought_about_this;
\set QUIET off

SELECT expect('and once it is gone the answer is zero again',
  (SELECT count(*) = 0 FROM unclassified_columns));


-- ── the scan ───────────────────────────────────────────────────────────────────

\echo ''
\echo '── a line on its way to the log stream'

SELECT expect('an ordinary request line passes',
  (SELECT count(*) = 0 FROM log_scan(
    '{"request_id":"req-1","user_id":"a1","resident_id":"e1","route":"POST /care-days","http_status":201,"ms":42}'::jsonb)));

SELECT expect('a care note in a log line is caught',
  (SELECT count(*) = 1 FROM log_scan(
    '{"request_id":"req-1","note":"she was frightened again tonight"}'::jsonb)
   WHERE field = 'note'));

SELECT expect('and so is one nested inside a serialised row, which is how it really happens',
  (SELECT count(*) = 1 FROM log_scan(
    '{"request_id":"req-1","row":{"id":"e1","display_name":"Cathy","mood":"agitated"}}'::jsonb)
   WHERE field = 'display_name' AND problem = 'nested field name'));

-- The two an independent review got past the first version, which looked at the top level
-- and one below it and no further.
SELECT expect('two levels down is caught',
  (SELECT count(*) = 1 FROM log_scan('{"ctx":{"request":{"note":"she was frightened"}}}'::jsonb)));

SELECT expect('and so is a row inside an array, which is what a list endpoint logs',
  (SELECT count(*) = 1 FROM log_scan(
    '{"rows":[{"id":"e1","display_name":"Cathy"},{"id":"e2","display_name":"Robert"}]}'::jsonb)));

SELECT expect('a sentence containing a name still passes, and the comment says so',
  (SELECT count(*) = 0 FROM log_scan('{"message":"Cathy was unsettled tonight"}'::jsonb)));

SELECT expect('an empty line is not reported as a problem',
  (SELECT count(*) = 0 FROM log_scan('{}'::jsonb)));

-- The naming rule this depends on, stated as a check so it is not folklore.
SELECT expect('status is on the list, which is why an HTTP status is logged as http_status',
  (SELECT count(*) = 1 FROM never_log WHERE field = 'status'));


-- ── what may be sent to a phone ────────────────────────────────────────────────

\echo ''
\echo '── notifications'

SELECT expect('there are templates, and every one of them is stored',
  (SELECT count(*) >= 5 FROM notification_templates));

SELECT expect('not one of them can name a resident',
  (SELECT count(*) = 0 FROM notification_templates
   WHERE body ILIKE '%{resident%' OR coalesce(title,'') ILIKE '%{resident%'));

SELECT expect('and not one carries a clinical word',
  (SELECT count(*) = 0 FROM notification_templates
   WHERE body ~* '(mood|appetite|slept|medication|refused|agitated|difficult night)'));

SELECT expect_rejected('the warm notification somebody will ask for', $$
  INSERT INTO notification_templates (id, channel, audience, body, placeholders)
  VALUES ('warm', 'push', 'family', '{resident_name} had a difficult night.',
          ARRAY['resident_name'])
$$);

SELECT expect_rejected('a placeholder used in the body but never declared', $$
  INSERT INTO notification_templates (id, channel, audience, body, placeholders)
  VALUES ('sneaky', 'push', 'family', 'An update about {mood}.', ARRAY['app_name'])
$$);

SELECT expect_rejected('a declared placeholder that is not on the allowed list', $$
  INSERT INTO notification_templates (id, channel, audience, body, placeholders)
  VALUES ('sneaky2', 'sms', 'family', 'Hello {note}.', ARRAY['note'])
$$);

-- The placeholder rule stopped a template interpolating a name and accepted any sentence
-- an author typed. "Patient Cathy had a fall" was a valid template until the fixed text
-- was checked too.
SELECT expect_rejected('a name typed straight into the body', $$
  INSERT INTO notification_templates (id, channel, audience, body, placeholders)
  VALUES ('typed', 'push', 'family', 'Patient Cathy had a fall.', ARRAY['app_name'])
$$);

SELECT expect_rejected('or a building name in the fixed text', $$
  INSERT INTO notification_templates (id, channel, audience, body, placeholders)
  VALUES ('building', 'sms', 'family', 'Cedar House has an update for you.', ARRAY['app_name'])
$$);

SELECT expect('and the invitation no longer names the building either',
  (SELECT body NOT ILIKE '%facility%' FROM notification_templates WHERE id = 'family_invitation'));

SELECT expect('which the vendor register and the template now agree on',
  (SELECT count(*) = 0 FROM notification_templates
   WHERE body ILIKE '%{facility_name}%'));

SELECT expect_rejected('a title that says what the body is not allowed to', $$
  INSERT INTO notification_templates (id, channel, audience, title, body, placeholders)
  VALUES ('sneaky3', 'push', 'family', '{resident_name}', 'There is a new update.',
          ARRAY['app_name'])
$$);

-- And the positive control: a template that follows the rule goes in.
\set QUIET on
INSERT INTO notification_templates (id, channel, audience, body, placeholders)
VALUES ('probe_ok', 'push', 'family', 'There are {count} new updates in {app_name}.',
        ARRAY['count','app_name']);
\set QUIET off
SELECT expect('a template within the rule is accepted',
  (SELECT count(*) = 1 FROM notification_templates WHERE id = 'probe_ok'));

\set QUIET on
DELETE FROM notification_templates WHERE id = 'probe_ok';
\set QUIET off

\echo '   every template, in full:'
SELECT channel, id, coalesce(title,'') AS title, body FROM notification_templates
ORDER BY channel, id;


-- ── what an engineer is told ───────────────────────────────────────────────────

\echo ''
\echo '── monitoring'

SELECT expect('every signal says what it watches, why, and who hears it',
  (SELECT count(*) = 0 FROM monitoring_signals
   WHERE watches = '' OR why = '' OR audience = ''));

SELECT expect('and there are enough of them to be a monitoring approach',
  (SELECT count(*) >= 6 FROM monitoring_signals));

SELECT expect_rejected('a signal that would carry a resident record to an on-call phone', $$
  INSERT INTO monitoring_signals (id, watches, why, alert_body, audience, carries_phi)
  VALUES ('leaky', 'care notes', 'to see what happened', '{note}', 'on-call', true)
$$);

SELECT expect('no alert body contains a field a log line may not contain',
  NOT EXISTS (
    SELECT 1 FROM monitoring_signals m
    JOIN never_log n ON m.alert_body ~ ('\{' || n.field || '\}')));

SELECT expect('the audit trail failing quietly is one of the things watched',
  (SELECT count(*) = 1 FROM monitoring_signals WHERE id = 'audit_write_failures'));

SELECT expect('and so is a restored copy nobody scrubbed',
  (SELECT count(*) = 1 FROM monitoring_signals WHERE id = 'unscrubbed_restore'));

-- The gap the package names as its weakest, and the compensating control for it. Denials
-- catch somebody reaching for what is not theirs; nothing caught somebody taking all of
-- what is.
SELECT expect('somebody taking every resident they are allowed to see is watched for',
  (SELECT count(*) = 1 FROM monitoring_signals WHERE id = 'bulk_read'));

SELECT expect('and so is the read trail quietly stopping',
  (SELECT count(*) = 1 FROM monitoring_signals WHERE id = 'read_audit_ratio'));

\echo ''
\echo '   what is watched:'
SELECT id, audience, alert_body FROM monitoring_signals ORDER BY id;

\set QUIET on
SELECT checks_end();
DROP FUNCTION expect(text, boolean);
DROP FUNCTION expect_rejected(text, text);
\set QUIET off
