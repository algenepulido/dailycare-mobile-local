-- The boundary between DailyCare and InkTree
--
-- Applied after encryption-and-secrets.sql.
--
-- The decision is that InkTree content flows into DailyCare and nothing flows back, and
-- the request was to design that so it can be revisited on purpose later rather than
-- coupled by accident now. Those are different problems. Deciding it takes a sentence;
-- keeping it takes a structure, because the accident does not look like a decision when it
-- happens. It looks like a feature.
--
-- Three things make the direction hold.
--
-- What may cross is a table, and every field on every channel is checked against the
-- classification. An outbound channel carrying a column classified as PHI is a failing
-- check rather than a conversation, so reversing the direction cannot be done by adding a
-- field to a payload.
--
-- What crosses outward carries a pseudonym, not a DailyCare identifier. InkTree can
-- correlate its own messages without ever holding something that points back into a care
-- record, and two integrations cannot compare notes.
--
-- And the databases stay apart. That is the one worth saying plainly, because the InkTree
-- field guide says every service reads and writes one Postgres instance directly, with no
-- events involved. There is no service-level isolation to lean on over there. The day
-- somebody adds a DailyCare schema to that instance - the cheapest and most natural thing
-- to propose - all nine services are handling PHI, and nothing published an event to say
-- so. So this database checks that nothing has joined it to another one.


CREATE TYPE flow_direction AS ENUM (
  'inbound',    -- into DailyCare. Safe: it lands inside controls that already exist.
  'outbound'    -- out of DailyCare. Every one of these is a HIPAA scope decision.
);

CREATE TABLE boundary_channels (
  id           text PRIMARY KEY,
  direction    flow_direction NOT NULL,
  carries      text NOT NULL,
  transport    text NOT NULL,
  is_open      boolean NOT NULL DEFAULT false,

  -- What somebody would have to do on purpose to change this. Written for the person who
  -- will read it in a year without the conversation that produced it.
  reversal_requires text NOT NULL,
  note         text,
  reviewed_on  date NOT NULL
);

COMMENT ON TABLE boundary_channels IS
  'Every path data may take between the two systems. A path not in here does not exist,
   which is the point: a new one is a row somebody has to write, and the checks then have
   something to refuse.';

CREATE TABLE boundary_fields (
  channel_id   text NOT NULL REFERENCES boundary_channels(id) ON DELETE CASCADE,
  table_name   text NOT NULL,
  column_name  text NOT NULL,
  note         text,
  PRIMARY KEY (channel_id, table_name, column_name)
);

COMMENT ON TABLE boundary_fields IS
  'What each channel actually carries, column by column, so it can be joined against the
   classification. This is what makes "nothing clinical leaves" checkable rather than
   agreed.';


-- ── the channels that exist ────────────────────────────────────────────────────

INSERT INTO boundary_channels (id, direction, carries, transport, is_open,
                               reversal_requires, note, reviewed_on) VALUES
('inktree_stories', 'inbound',
 'Stories a family has recorded in InkTree, so a caregiver can know who they are looking after.',
 'DailyCare polls a narrow read API on the InkTree side, authenticated as DailyCare.',
 false,
 'Nothing. It is inbound, and inbound is the safe direction. Closing it would be the decision.',
 'A pull rather than a subscription on purpose. Subscribing to their event bus would put DailyCare inside a channel that also carries billing, calls and notifications, and would mean holding a credential to all of it for the sake of a story feed.',
 DATE '2026-09-16'),

('inktree_photos', 'inbound',
 'Family photographs attached to a story.',
 'The same pull. Objects are copied into DailyCare storage rather than linked, so a photograph a caregiver shows a resident does not depend on a URL somebody else controls.',
 false,
 'Nothing. Inbound.',
 'Copied rather than hot-linked: a link would mean an InkTree request log recording which resident was shown which photograph and when, which is an access pattern about a person in care.',
 DATE '2026-09-16'),

('inktree_family_context', 'inbound',
 'Who is who in the family, so a caregiver knows that the man on the phone is a son and not a neighbour.',
 'The same pull. Mapped onto resident_contacts.relation, which is already the shape InkTree uses.',
 false, 'Nothing. Inbound.',
 'The one place the two models genuinely meet. InkTree reached relation = self rather than is_user the expensive way and DailyCare matched that shape on purpose, so this is a mapping rather than a translation.',
 DATE '2026-09-16'),

('dailycare_activity_signal', 'outbound',
 'That something happened for a pseudonymous subject, and when. No name, no facility, nothing clinical, no DailyCare identifier.',
 'DailyCare would post to an InkTree endpoint. Nothing does today.',
 false,
 'An agreement with InkTree covering it, and the decision recorded here. A stable code plus timestamps is a pseudonymous record of a person: Safe Harbor excludes codes derived from patient identifiers, so this is a disclosure however little it says. Opening it is therefore a BAA and a signature, not a configuration change.',
 'Written down while shut so that the shape of a reversal exists before somebody needs it in a hurry. It is the narrowest outbound channel anybody could want - a pseudonym, a constant, a timestamp - and it still crosses the line, which is the useful thing it demonstrates.',
 DATE '2026-09-16');


-- ── the imported content, which is DailyCare's the moment it lands ─────────────

CREATE TYPE imported_kind AS ENUM ('story', 'photograph', 'family_context');

CREATE TABLE imported_content (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  facility_id   uuid NOT NULL REFERENCES facilities(id) ON DELETE RESTRICT,
  resident_id   uuid NOT NULL,

  source        text NOT NULL DEFAULT 'inktree',
  external_ref  text NOT NULL,          -- their id for it, so a re-import is not a duplicate
  kind          imported_kind NOT NULL,

  title         text,
  body          text,
  media_id      uuid REFERENCES media_objects(id) ON DELETE SET NULL ON UPDATE CASCADE,

  imported_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source, external_ref, resident_id),

  -- The resident and the facility together. See schema.sql: two references each
  -- holding is not the same as the pair agreeing.
  FOREIGN KEY (resident_id, facility_id)
    REFERENCES residents (id, facility_id) ON DELETE RESTRICT ON UPDATE CASCADE
);

CREATE INDEX ON imported_content (resident_id, kind);

COMMENT ON TABLE imported_content IS
  'A family story is not health information. A family story filed against a named resident
   in memory care is attached to a patient, and that is what the term means - so this is
   PHI from the moment it arrives, and is governed by the same policies as a care day. The
   content did not change; what changed is what it is attached to.';


-- ── and the table that is the reason the boundary needs a structure ────────────

CREATE TYPE reminiscence_response AS ENUM (
  'recognised', 'engaged', 'unsettled', 'no_response', 'declined'
);

CREATE TABLE content_responses (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  facility_id   uuid NOT NULL REFERENCES facilities(id) ON DELETE RESTRICT,
  resident_id   uuid NOT NULL,
  content_id    uuid NOT NULL REFERENCES imported_content(id) ON DELETE CASCADE ON UPDATE CASCADE,

  response      reminiscence_response NOT NULL,
  note          text NOT NULL DEFAULT '',
  observed_at   timestamptz NOT NULL DEFAULT now(),
  observed_by   uuid NOT NULL REFERENCES users(id),

  -- The resident and the facility together. See schema.sql: two references each
  -- holding is not the same as the pair agreeing.
  FOREIGN KEY (resident_id, facility_id)
    REFERENCES residents (id, facility_id) ON DELETE RESTRICT ON UPDATE CASCADE
);

CREATE INDEX ON content_responses (resident_id, observed_at DESC);

COMMENT ON TABLE content_responses IS
  'How a resident responded to a memory. Clinical observation about a person in care, and
   the single most likely way the boundary gets reversed - because the feature that wants
   it does not look like a data flow. It looks like better recommendations: show a story,
   record the reaction, send the reaction back so the next story is chosen better. That
   third step is a resident''s response to a memory leaving the agreement boundary, and
   nobody in the room would describe it as sending PHI to a vendor. No outbound channel may
   reference this table, which is checked rather than agreed.';


-- ── the pseudonym ──────────────────────────────────────────────────────────────

CREATE TABLE integration_salts (
  integration text PRIMARY KEY,
  salt        text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE integration_salts IS
  'One salt per integration, so the pseudonym a partner sees is theirs alone. Two partners
   comparing lists learn nothing, and a leaked list from one is not a key to the other.';

INSERT INTO integration_salts (integration, salt)
VALUES ('inktree', encode(gen_random_bytes(32), 'hex'));

CREATE OR REPLACE FUNCTION resident_pseudonym(target_resident uuid, integration text)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = pg_catalog, public AS $$
  SELECT encode(digest(s.salt || target_resident::text, 'sha256'), 'hex')
  FROM integration_salts s WHERE s.integration = resident_pseudonym.integration
$$;

COMMENT ON FUNCTION resident_pseudonym(uuid, text) IS
  'Deterministic so a partner can correlate their own messages, and keyed per integration so
   nobody else can. Not reversible without the salt, which never leaves this database.';


-- ── what would leave, if the valve were opened ─────────────────────────────────
--
-- The table exists and is empty. Nothing writes to it, because the channel is shut. It is
-- here so that the shape of a reversal is written down rather than invented in a hurry by
-- whoever eventually needs it, and so that the checks below have something to refuse.
--
-- Writing it down is also what showed the design was wrong the first time. The obvious
-- version derived this straight from care_days, which meant a column added to care_days
-- could widen the outbound payload without anybody touching this file. It goes through its
-- own table for the same reason an API has a serialiser: so the thing that leaves is
-- declared rather than inherited.

CREATE TABLE outbound_signals (
  id            bigserial PRIMARY KEY,
  subject       text NOT NULL,          -- the pseudonym, resolved once at write time
  signal        text NOT NULL,          -- 'care_day_filed'. A name, not a value.
  occurred_at   timestamptz NOT NULL DEFAULT now(),
  delivered_at  timestamptz
);

COMMENT ON TABLE outbound_signals IS
  'Empty, and checked to be empty. The resident uuid is deliberately absent even here: the
   pseudonym is resolved when the row is written, so a copy of this table is not a key back
   into a care record.

   The subject is classified as identifying rather than operational, and that is the
   uncomfortable and correct answer. A code derived from a patient identifier is not
   de-identified data - Safe Harbor excludes exactly this - and a partner who receives a
   stable code plus timestamps holds a pseudonymous record of a person even without knowing
   which person. So opening this channel is a disclosure and needs an agreement with
   InkTree, which is what boundary_blocked_channels says and what it would cost. Classifying
   it as operational to make a check pass would have been the easy and dishonest version.';


-- ════════════════════════════════════════════════════════════════════ the checks
--
-- The rule is one join. Everything else is arrangement.

CREATE VIEW boundary_leaks AS
SELECT bc.id AS channel, bf.table_name, bf.column_name, dc.class
FROM boundary_channels bc
JOIN boundary_fields bf ON bf.channel_id = bc.id
JOIN data_classification dc
  ON dc.table_name = bf.table_name AND dc.column_name = bf.column_name
WHERE bc.direction = 'outbound' AND bc.is_open
  AND dc.class IN ('phi', 'identifying', 'secret');

COMMENT ON VIEW boundary_leaks IS
  'Must be empty. An open outbound channel carrying a column the classification calls PHI
   is the reversal having happened, whether or not anybody described it that way.';

CREATE VIEW boundary_blocked_channels AS
SELECT DISTINCT bc.id AS channel, bc.carries, bc.reversal_requires,
       (SELECT string_agg(DISTINCT dc2.class::text, ', ')
        FROM boundary_fields bf2
        JOIN data_classification dc2
          ON dc2.table_name = bf2.table_name AND dc2.column_name = bf2.column_name
        WHERE bf2.channel_id = bc.id
          AND dc2.class IN ('phi','identifying','secret')) AS would_carry
FROM boundary_channels bc
WHERE bc.direction = 'outbound' AND NOT bc.is_open
  AND EXISTS (SELECT 1 FROM boundary_fields bf
              JOIN data_classification dc
                ON dc.table_name = bf.table_name AND dc.column_name = bf.column_name
              WHERE bf.channel_id = bc.id
                AND dc.class IN ('phi','identifying','secret'));

COMMENT ON VIEW boundary_blocked_channels IS
  'Expected to have rows, and today it has one. These are the reversals that have been
   thought about and are shut: each says what it would carry and what opening it would
   require. A register that could only hold good news would have nothing to say on the day
   somebody proposes one of these, which is the day it matters.';

CREATE VIEW boundary_unspecified AS
SELECT id, direction, carries FROM boundary_channels bc
WHERE NOT EXISTS (SELECT 1 FROM boundary_fields bf WHERE bf.channel_id = bc.id);

COMMENT ON VIEW boundary_unspecified IS
  'Must be empty for outbound channels. A channel whose fields nobody listed cannot be
   checked, and an unchecked outbound channel is the same as an open one.';

CREATE VIEW boundary_reminiscence_leak AS
SELECT bc.id AS channel, bf.table_name, bf.column_name, bc.is_open
FROM boundary_channels bc
JOIN boundary_fields bf ON bf.channel_id = bc.id
WHERE bc.direction = 'outbound'
  AND bf.table_name IN (SELECT DISTINCT table_name FROM data_classification
                        WHERE class = 'phi');

COMMENT ON VIEW boundary_reminiscence_leak IS
  'Must be empty, and deliberately a different question from boundary_leaks. That one asks
   whether an open channel carries a classified column. This one asks whether any outbound
   channel, open or shut, so much as names a table that holds a resident''s record - which
   catches a column added to such a table before anybody has classified it, and catches a
   field added to a channel that is still shut, where boundary_leaks by design says nothing.

   The table list is generated rather than written out. The first version named five tables
   by hand and missed residents, which a check caught by adding a resident name to a payload
   and watching nothing happen.';

-- The other way the two systems get joined, and the likelier one.
CREATE VIEW boundary_database_joins AS
SELECT 'foreign server' AS kind, srvname AS name FROM pg_foreign_server
UNION ALL
SELECT 'foreign data wrapper', fdwname FROM pg_foreign_data_wrapper
UNION ALL
SELECT 'extension', extname FROM pg_extension
WHERE extname IN ('dblink', 'postgres_fdw', 'mysql_fdw', 'oracle_fdw');

COMMENT ON VIEW boundary_database_joins IS
  'Must be empty. The InkTree platform is one Postgres instance that every one of its
   services reads and writes directly, so joining this database to that one - a foreign
   data wrapper, a dblink, or simply putting a DailyCare schema in their instance - puts
   nine services and their vendors into scope without any event being published to say so.
   It is the cheapest thing to propose and the most expensive thing to have done.';


-- ════════════════════════════════════════════════════════════════════ the fields
--
-- Listed after the views so that a mistake here is caught by them.

INSERT INTO boundary_fields (channel_id, table_name, column_name, note) VALUES
('inktree_stories','imported_content','body','Their content, arriving. Inbound, so the classification is about what it becomes here, not about where it came from.'),
('inktree_stories','imported_content','title',NULL),
('inktree_stories','imported_content','external_ref',NULL),
('inktree_photos','imported_content','media_id',NULL),
('inktree_photos','imported_content','external_ref',NULL),
('inktree_family_context','resident_contacts','relation',NULL),

-- The outbound one, in full, and it names its own table rather than a care table.
('dailycare_activity_signal','outbound_signals','subject','A per-integration pseudonym. Classified identifying, which is why this channel is shut.'),
('dailycare_activity_signal','outbound_signals','signal','A constant name, not a value. "care_day_filed", never what was filed.'),
('dailycare_activity_signal','outbound_signals','occurred_at','When, not what. The care date itself is withheld even here: a gap in care dates is an observation about somebody.');


-- ════════════════════════════════════════════════════════════════════ access
--
-- Imported content and the responses to it are resident records. They resolve through the
-- same predicates as a care day, so there is no second access model to keep in step.

ALTER TABLE imported_content   ENABLE ROW LEVEL SECURITY;
ALTER TABLE imported_content   FORCE  ROW LEVEL SECURITY;
ALTER TABLE content_responses  ENABLE ROW LEVEL SECURITY;
ALTER TABLE content_responses  FORCE  ROW LEVEL SECURITY;

CREATE POLICY imported_content_read ON imported_content FOR SELECT
  USING (app_may_read_resident(resident_id, facility_id));
CREATE POLICY imported_content_insert ON imported_content FOR INSERT
  WITH CHECK (app_may_write_resident(resident_id, facility_id));

CREATE POLICY content_responses_read ON content_responses FOR SELECT
  USING (app_may_read_resident(resident_id, facility_id));
CREATE POLICY content_responses_insert ON content_responses FOR INSERT
  WITH CHECK (app_may_write_resident(resident_id, facility_id));

-- Family may read a story. A family member reading how their mother responded to it is a
-- different question, and the answer here is no: an observation a caregiver made is a care
-- record, and the family surface shows the daily summary rather than the clinical note
-- behind it.
CREATE POLICY content_responses_staff_only ON content_responses AS RESTRICTIVE FOR SELECT
  USING (app_may_write_resident(resident_id, facility_id));

CREATE TRIGGER audit_imported_content
  AFTER INSERT OR UPDATE ON imported_content
  FOR EACH ROW EXECUTE FUNCTION audit_phi_write('resident_id');
CREATE TRIGGER audit_content_responses
  AFTER INSERT OR UPDATE ON content_responses
  FOR EACH ROW EXECUTE FUNCTION audit_phi_write('resident_id');

-- Retention takes them with the resident they belong to.
CREATE POLICY imported_content_retention_select ON imported_content FOR SELECT
  TO dailycare_retention USING (true);
CREATE POLICY imported_content_retention_delete ON imported_content FOR DELETE
  TO dailycare_retention USING (retention_resident_expired(resident_id));
CREATE POLICY content_responses_retention_select ON content_responses FOR SELECT
  TO dailycare_retention USING (true);
CREATE POLICY content_responses_retention_delete ON content_responses FOR DELETE
  TO dailycare_retention USING (retention_resident_expired(resident_id));

GRANT SELECT (id, resident_id), DELETE ON imported_content  TO dailycare_retention;
GRANT SELECT (id, resident_id), DELETE ON content_responses TO dailycare_retention;

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dailycare_app') THEN
    REVOKE ALL ON boundary_channels, boundary_fields, integration_salts FROM dailycare_app;
    GRANT SELECT ON boundary_channels TO dailycare_app;
  END IF;
END $$;


-- ════════════════════════════════════════════════════════════════════ classification
--
-- A story is not health information. A story filed against a named resident in memory care
-- is attached to a patient. The content did not change; what it is attached to did.

INSERT INTO data_classification (table_name, column_name, class, note) VALUES
 ('imported_content','id','operational',NULL),
 ('imported_content','facility_id','operational',NULL),
 ('imported_content','resident_id','phi','Which resident a memory belongs to.'),
 ('imported_content','source','operational',NULL),
 ('imported_content','external_ref','operational','Their identifier for it, opaque here.'),
 ('imported_content','kind','operational',NULL),
 ('imported_content','title','phi','A family story attached to a person in care.'),
 ('imported_content','body','phi','As above. Stricter than the content alone would need, and deliberately so.'),
 ('imported_content','media_id','phi','Points at a photograph of, or shown to, a resident.'),
 ('imported_content','imported_at','operational',NULL),

 ('content_responses','id','operational',NULL),
 ('content_responses','facility_id','operational',NULL),
 ('content_responses','resident_id','phi',NULL),
 ('content_responses','content_id','phi','Which memory. The pairing is the observation.'),
 ('content_responses','response','phi','How a resident responded to a memory. Clinical.'),
 ('content_responses','note','phi','A caregiver''s words about that response.'),
 ('content_responses','observed_at','phi','When a resident was unsettled is an observation about them.'),
 ('content_responses','observed_by','identifying','Which caregiver, who is staff rather than the patient.'),

 ('outbound_signals','id','operational',NULL),
 ('outbound_signals','subject','identifying','A code derived from a patient identifier is not de-identified data. This is why the channel is shut.'),
 ('outbound_signals','signal','operational','A constant name.'),
 ('outbound_signals','occurred_at','operational','Alone, with no subject, this says nothing.'),
 ('outbound_signals','delivered_at','operational',NULL),

 ('boundary_channels','id','operational',NULL),
 ('boundary_channels','direction','operational',NULL),
 ('boundary_channels','carries','operational',NULL),
 ('boundary_channels','transport','operational',NULL),
 ('boundary_channels','is_open','operational',NULL),
 ('boundary_channels','reversal_requires','operational',NULL),
 ('boundary_channels','note','operational',NULL),
 ('boundary_channels','reviewed_on','operational',NULL),

 ('boundary_fields','channel_id','operational',NULL),
 ('boundary_fields','table_name','operational',NULL),
 ('boundary_fields','column_name','operational',NULL),
 ('boundary_fields','note','operational',NULL),

 ('integration_salts','integration','operational',NULL),
 ('integration_salts','salt','secret','The only thing that turns a pseudonym back into a resident. Never leaves this database.'),
 ('integration_salts','created_at','operational',NULL);


-- ════════════════════════════════════════════════════════════════════ non-production
--
-- A developer needs imported content that looks like imported content. They do not need
-- anybody's grandmother.

INSERT INTO scrub_rules (table_name, column_name, strategy, reason) VALUES
 ('imported_content','title','redact_text',NULL),
 ('imported_content','body','redact_text',NULL),
 ('imported_content','resident_id','keep','A generated uuid pointing at a resident who has been renamed.'),
 ('imported_content','media_id','keep','A uuid pointing at a media row whose path has been hashed.'),
 ('content_responses','resident_id','keep','As above.'),
 ('content_responses','content_id','keep','The pairing is what makes a reminiscence screen worth building against.'),
 ('content_responses','response','keep','A fixed vocabulary detached from identity, and the distribution is the point of having it.'),
 ('content_responses','note','redact_text',NULL),
 ('content_responses','observed_at','shift_days',NULL),
 ('content_responses','observed_by','keep','A uuid pointing at a staff account that has been renamed.'),
 ('outbound_signals','subject','hash_token',NULL),
 ('integration_salts','salt','scramble_digest','A dev copy that kept the salt could turn production pseudonyms back into residents.');


-- ════════════════════════════════════════════════════════════════════ the matrix
--
-- Two new tables holding a resident's record, so two new blocks in the access matrix.
-- Family read a story and do not read what a caregiver observed about it.

INSERT INTO access_matrix (actor, table_name, operation, allowed, condition, note)
SELECT a.actor, 'imported_content', m.operation, m.allowed,
       CASE WHEN m.allowed THEN m.condition END, NULL
FROM (SELECT actor, operation, allowed, condition FROM access_matrix
      WHERE table_name = 'care_days') m
JOIN (SELECT DISTINCT actor FROM access_matrix) a ON a.actor = m.actor;

INSERT INTO access_matrix (actor, table_name, operation, allowed, condition, note) VALUES
('caregiver','content_responses','select',true,'For residents assigned to them',NULL),
('caregiver','content_responses','insert',true,'For residents assigned to them',NULL),
('caregiver','content_responses','update',false,NULL,'An observation is a fact about a moment.'),
('caregiver','content_responses','delete',false,NULL,NULL),
('care_manager','content_responses','select',true,'Every response in their facility',NULL),
('care_manager','content_responses','insert',true,'For residents in their facility',NULL),
('care_manager','content_responses','update',false,NULL,NULL),
('care_manager','content_responses','delete',false,NULL,NULL),
('family','content_responses','select',false,NULL,'A family member reads the story and the daily summary. How their mother responded to a memory is a caregiver''s clinical observation, and the restrictive policy refuses it rather than relying on the surface not asking.'),
('family','content_responses','insert',false,NULL,NULL),
('family','content_responses','update',false,NULL,NULL),
('family','content_responses','delete',false,NULL,NULL),
('integration','content_responses','select',false,NULL,NULL),
('integration','content_responses','insert',false,NULL,NULL),
('integration','content_responses','update',false,NULL,NULL),
('integration','content_responses','delete',false,NULL,NULL),
('retention','content_responses','select',true,'Identifiers only',NULL),
('retention','content_responses','insert',false,NULL,NULL),
('retention','content_responses','update',false,NULL,NULL),
('retention','content_responses','delete',true,'Only responses belonging to an expired resident',NULL),
('unidentified','content_responses','select',false,NULL,NULL),
('unidentified','content_responses','insert',false,NULL,NULL),
('unidentified','content_responses','update',false,NULL,NULL),
('unidentified','content_responses','delete',false,NULL,NULL);


-- ════════════════════════════════════════════════════════════════════ retention
--
-- Imported content and the responses to it go with the resident they belong to, and go
-- before the resident does, because both reference them.

CREATE OR REPLACE FUNCTION retention_delete_boundary_rows(due uuid[])
RETURNS TABLE (what text, removed bigint)
LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
DECLARE n bigint;
BEGIN
  DELETE FROM content_responses WHERE resident_id = ANY(due);
  GET DIAGNOSTICS n = ROW_COUNT;
  what := 'reminiscence responses'; removed := n; RETURN NEXT;

  DELETE FROM imported_content WHERE resident_id = ANY(due);
  GET DIAGNOSTICS n = ROW_COUNT;
  what := 'imported content'; removed := n; RETURN NEXT;
  RETURN;
END; $$;

COMMENT ON FUNCTION retention_delete_boundary_rows(uuid[]) IS
  'Called by apply_retention. Separate so that this file owns the tables it added rather
   than editing the retention job every time the schema grows.';
