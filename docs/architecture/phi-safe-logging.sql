-- PHI-safe logging, monitoring and notification
--
-- Applied after data-classification.sql.
--
-- A log line is written by a person, months after the rule was agreed, at two in the
-- morning, while trying to work out why something is broken. That is the honest model of
-- how a resident's name ends up in Cloud Logging, and no policy document survives it.
--
-- So the rule is generated rather than remembered. The classification already knows which
-- columns hold a resident's record; never_log turns that into the list of field names a log
-- line may not contain, log_scan checks a candidate line against it, and the application's
-- logger is tested against both. A column added in a later migration joins the list without
-- anybody updating a document.
--
-- Notifications are the same problem with a worse blast radius, because the text ends up on
-- a lock screen in a room with other people in it. A template is a row with a constraint,
-- and a template that interpolates a clinical field is refused rather than reviewed.


-- ════════════════════════════════════════════════════════════════════ what may not be logged

CREATE VIEW never_log AS
SELECT column_name AS field,
       min(class::text) AS strictest_class,
       array_agg(DISTINCT table_name ORDER BY table_name) AS appears_in
FROM data_classification
WHERE class IN ('phi', 'identifying', 'secret')
  -- Identifiers are the whole point: a log line is useful because it carries these.
  AND column_name NOT IN ('id', 'resident_id', 'facility_id', 'user_id', 'care_day_id')
-- One row per name rather than one per column, because a log line has field names and not
-- tables. display_name is PHI on residents and merely identifying on users; it is the same
-- forbidden key either way, and the stricter of the two is the one recorded.
GROUP BY column_name
ORDER BY column_name;

COMMENT ON VIEW never_log IS
  'Generated from the classification, so it cannot fall behind the schema. What is left out
   is deliberate: a uuid in a log line is what makes the line worth having, and a uuid on
   its own identifies nobody outside the database.

   Several of these collide with ordinary logging vocabulary - status, source, detail,
   amount. That is not a false positive to be tuned away; it is a naming rule. A log line
   records http_status, not status, and request_source, not source. The collision is worth
   keeping, because the day somebody logs the medication status into a field called status
   is the day the guard was supposed to fire.';


-- The application's logger calls this on the structured line it is about to emit, in
-- development and in test. It is a guard rather than a filter: the answer is not "we
-- removed the name", it is "this line should not have been written".
CREATE OR REPLACE FUNCTION log_scan(line jsonb)
RETURNS TABLE (problem text, field text)
LANGUAGE sql STABLE
  SET search_path = pg_catalog, public AS $$
  -- A forbidden field name used as a key.
  SELECT 'field name', k
  FROM jsonb_object_keys(line) k
  WHERE k IN (SELECT field FROM never_log)
  UNION ALL
  -- A nested object carrying one.
  SELECT 'nested field name', k2
  FROM jsonb_each(line) e, jsonb_object_keys(e.value) k2
  WHERE jsonb_typeof(e.value) = 'object' AND k2 IN (SELECT field FROM never_log)
$$;

COMMENT ON FUNCTION log_scan(jsonb) IS
  'Returns nothing for a line that is safe to emit. Catches the shape of the mistake - a
   field called note, or display_name, appearing in a log line - rather than trying to
   recognise a resident''s name, which is not a thing a function can do.';


-- ════════════════════════════════════════════════════════════════════ what may be sent

CREATE TYPE notification_channel AS ENUM ('push', 'sms', 'email');

CREATE TABLE notification_templates (
  id          text PRIMARY KEY,
  channel     notification_channel NOT NULL,
  audience    text NOT NULL,
  title       text,
  body        text NOT NULL,

  -- Every {placeholder} the body is allowed to use. Anything else in the body is a
  -- rejected row, and anything in here that names a clinical field is a rejected row.
  placeholders text[] NOT NULL DEFAULT '{}',
  note        text
);

-- The only placeholders that exist. None of them is about a resident's day.
CREATE OR REPLACE FUNCTION notification_placeholder_allowed(p text)
RETURNS boolean LANGUAGE sql IMMUTABLE
  SET search_path = pg_catalog, public AS $$
  SELECT p IN ('facility_name',   -- a business, not a person
                'app_name',
                'code',           -- a sign-in code
                'link',           -- opens the app, which then authenticates
                'count')          -- "2 new updates"
$$;

CREATE OR REPLACE FUNCTION notification_body_is_safe(body text, declared text[])
RETURNS boolean LANGUAGE plpgsql IMMUTABLE
  SET search_path = pg_catalog, public AS $$
DECLARE used text[];
BEGIN
  SELECT coalesce(array_agg(m[1]), '{}') INTO used
  FROM regexp_matches(body, '\{([a-z_]+)\}', 'g') m;
  -- Every placeholder in the body must be declared, and every declared one allowed.
  RETURN NOT EXISTS (SELECT 1 FROM unnest(used) u WHERE NOT (u = ANY(declared)))
     AND NOT EXISTS (SELECT 1 FROM unnest(declared) d WHERE NOT notification_placeholder_allowed(d));
END; $$;

ALTER TABLE notification_templates
  ADD CONSTRAINT notification_body_carries_nothing_clinical
  CHECK (notification_body_is_safe(body, placeholders)
     AND (title IS NULL OR notification_body_is_safe(title, placeholders)));

COMMENT ON CONSTRAINT notification_body_carries_nothing_clinical ON notification_templates IS
  'The tempting version of this feature is "Cathy had a difficult night", and it puts a
   health fact on a lock screen in a room with other people in it. There is no placeholder
   for a resident name and none for anything clinical, so the tempting version cannot be
   written down, let alone sent.';


INSERT INTO notification_templates (id, channel, audience, title, body, placeholders, note) VALUES
('family_update', 'push', 'family',
 'A new update', 'There is a new update in {app_name}.', ARRAY['app_name'],
 'No name and no content. The family opens the app, authenticates, and reads the day inside the access model.'),

('family_multiple', 'push', 'family',
 'New updates', 'You have {count} new updates in {app_name}.', ARRAY['count','app_name'],
 'A count is not a clinical fact.'),

('family_invitation', 'sms', 'family',
 NULL, '{facility_name} has invited you to {app_name}. {link}', ARRAY['facility_name','app_name','link'],
 'A facility name is a business name. The link opens the app, which then authenticates - it is not a link to a record.'),

('sign_in_code', 'sms', 'any',
 NULL, 'Your {app_name} sign-in code is {code}.', ARRAY['app_name','code'],
 NULL),

('caregiver_reminder', 'push', 'caregiver',
 'Days still to file', 'You have {count} days still to file.', ARRAY['count'],
 'Deliberately not "Cathy''s day is not filed". A caregiver opens the app and sees whose.');


CREATE VIEW notification_audit AS
SELECT id, channel, audience, body,
       (SELECT count(*) FROM regexp_matches(body, '\{([a-z_]+)\}', 'g')) AS placeholders_used
FROM notification_templates ORDER BY channel, id;


-- ════════════════════════════════════════════════════════════════════ monitoring
--
-- What is watched, what it is allowed to say, and who hears about it. An alert is a
-- notification with an engineer as the audience, and the same rule applies: it names a
-- facility and a count, never a resident.

CREATE TABLE monitoring_signals (
  id            text PRIMARY KEY,
  watches       text NOT NULL,
  why           text NOT NULL,
  alert_body    text NOT NULL,
  audience      text NOT NULL,
  carries_phi   boolean NOT NULL DEFAULT false,
  CONSTRAINT monitoring_carries_no_phi CHECK (NOT carries_phi)
);

COMMENT ON CONSTRAINT monitoring_carries_no_phi ON monitoring_signals IS
  'A column that can only ever be false looks redundant. It is there so that adding a signal
   that would carry a resident''s record is a refused insert and a conversation, rather than
   a field somebody set to true without noticing what it meant.';

INSERT INTO monitoring_signals (id, watches, why, alert_body, audience) VALUES
('auth_failures', 'Failed sign-ins per account and per address',
 'Credential stuffing looks like this before it looks like anything else.',
 '{count} failed sign-ins for one account in {window}', 'on-call'),

('policy_denials', 'Requests refused by row-level security',
 'A handful is normal. A spike is either a bug that lost the session identity or somebody reaching for records that are not theirs.',
 '{count} access denials in {window}, {distinct_users} accounts', 'on-call'),

('audit_write_failures', 'Inserts into audit_events that did not happen',
 'The trail failing quietly is worse than the write failing loudly.',
 'audit trigger error rate above threshold', 'on-call'),

('retention_overdue', 'Facilities whose retention job has not run',
 'A record kept past its window is a finding, and nothing else would notice.',
 '{count} facilities overdue for retention', 'on-call'),

('unscrubbed_restore', 'Non-production databases serving nothing',
 'A restored copy that has sat unscrubbed for a day is somebody who has forgotten about it.',
 '{environment} has been unscrubbed for {hours} hours', 'engineering'),

('media_orphans', 'Objects in storage with no row, and rows with no object',
 'Either direction means the handshake broke, and one of them leaves a photograph in a bucket with nothing that knows whose it was.',
 '{count} orphaned objects in {bucket}', 'engineering'),

('backup_age', 'Time since the last verified snapshot',
 'A backup nobody checked is a backup nobody has.',
 'last verified snapshot is {hours} hours old', 'on-call');


DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dailycare_app') THEN
    GRANT SELECT ON never_log, notification_templates, monitoring_signals TO dailycare_app;
    GRANT EXECUTE ON FUNCTION log_scan(jsonb) TO dailycare_app;
  END IF;
END $$;
