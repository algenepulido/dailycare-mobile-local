-- The role and access-control matrix
--
-- Applied after access-policies.sql.
--
-- A matrix in a document says what the application intends. The policies say what the
-- database will permit. The two agree on the day the document is written and drift
-- afterwards, and the drift is invisible because nothing compares them.
--
-- So the matrix is a table, and it is checked from both sides.
--
-- Structurally, against the catalogue: if the matrix says nobody may delete a care record
-- and a DELETE policy appears for an application role, that is a failing check rather than
-- a stale paragraph. Behaviourally, against the running database: access-invariants.sql
-- becomes each actor in turn and counts what they can actually reach, and those counts are
-- compared with the cells here.
--
-- The actors are the product's roles, not PostgreSQL's. A caregiver and a care manager
-- connect as the same database role and are told apart by the session, which is why the
-- matrix cannot simply be read out of pg_policies.

CREATE TYPE access_actor AS ENUM (
  'caregiver',        -- files care for the residents assigned to them
  'care_manager',     -- runs a facility: every resident in it, and who may see them
  'family',           -- one resident, read only, by grant
  'integration',      -- the clinical-system feed
  'retention',        -- the scheduled deletion job
  'unidentified'      -- a request that did not say who it is
);

CREATE TYPE access_operation AS ENUM ('select', 'insert', 'update', 'delete');

CREATE TABLE access_matrix (
  actor       access_actor NOT NULL,
  table_name  text NOT NULL,
  operation   access_operation NOT NULL,
  allowed     boolean NOT NULL,

  -- Empty when allowed is false. When true, the condition is the interesting part: almost
  -- nothing here is allowed unconditionally.
  condition   text,
  note        text,
  PRIMARY KEY (actor, table_name, operation),
  CHECK (allowed = (condition IS NOT NULL))
);

COMMENT ON TABLE access_matrix IS
  'Every actor against every table holding a resident record, for every operation. A blank
   cell is not an answer, so the completeness check requires all of them.';


-- ── residents ──────────────────────────────────────────────────────────────────

INSERT INTO access_matrix (actor, table_name, operation, allowed, condition, note) VALUES
('caregiver','residents','select',true,'Residents currently assigned to them','Not the building. The stricter reading of least privilege, and flagged for the reviewer as possibly operationally wrong for a facility that rotates staff hourly.'),
('caregiver','residents','insert',false,NULL,'Admitting a resident is a manager''s act.'),
('caregiver','residents','update',false,NULL,NULL),
('caregiver','residents','delete',false,NULL,NULL),
('care_manager','residents','select',true,'Every resident in their own facility',NULL),
('care_manager','residents','insert',true,'Into their own facility only',NULL),
('care_manager','residents','update',true,'Their own facility only',NULL),
('care_manager','residents','delete',false,NULL,'Nobody deletes a resident through the application. Departure is a date, and destruction is retention''s.'),
('family','residents','select',true,'The one resident they hold an active grant for',NULL),
('family','residents','insert',false,NULL,NULL),
('family','residents','update',false,NULL,NULL),
('family','residents','delete',false,NULL,NULL),
('integration','residents','select',false,NULL,'The feed writes medication events and reads nothing.'),
('integration','residents','insert',false,NULL,NULL),
('integration','residents','update',false,NULL,NULL),
('integration','residents','delete',false,NULL,NULL),
('retention','residents','select',true,'Identifier and facility only. Not the name.','Column-level: the retention role is refused display_name outright.'),
('retention','residents','insert',false,NULL,NULL),
('retention','residents','update',false,NULL,NULL),
('retention','residents','delete',true,'Only a resident whose facility''s retention window has closed','Re-checked by the database independently of the job that asks.'),
('unidentified','residents','select',false,NULL,'app_user_id() is null and null compares false everywhere.'),
('unidentified','residents','insert',false,NULL,NULL),
('unidentified','residents','update',false,NULL,NULL),
('unidentified','residents','delete',false,NULL,NULL);

-- ── care days, and the two tables that hang off them ───────────────────────────

INSERT INTO access_matrix (actor, table_name, operation, allowed, condition, note) VALUES
('caregiver','care_days','select',true,'For residents assigned to them',NULL),
('caregiver','care_days','insert',true,'For residents assigned to them',NULL),
('caregiver','care_days','update',true,'To supersede a day they may write','The only update. A day''s contents are never rewritten; a correction is a new row.'),
('caregiver','care_days','delete',false,NULL,'No DELETE policy exists on this table for any application role.'),
('care_manager','care_days','select',true,'Every care day in their facility',NULL),
('care_manager','care_days','insert',true,'For residents in their facility',NULL),
('care_manager','care_days','update',true,'To supersede a day in their facility',NULL),
('care_manager','care_days','delete',false,NULL,NULL),
('family','care_days','select',true,'For the resident they hold a grant for',NULL),
('family','care_days','insert',false,NULL,'The whole reason read and write are separate predicates.'),
('family','care_days','update',false,NULL,NULL),
('family','care_days','delete',false,NULL,NULL),
('integration','care_days','select',false,NULL,NULL),
('integration','care_days','insert',false,NULL,NULL),
('integration','care_days','update',false,NULL,NULL),
('integration','care_days','delete',false,NULL,NULL),
('retention','care_days','select',true,'Identifiers only. Not the note, the mood or anything clinical.',NULL),
('retention','care_days','insert',false,NULL,NULL),
('retention','care_days','update',false,NULL,NULL),
('retention','care_days','delete',true,'Only days belonging to an expired resident',NULL),
('unidentified','care_days','select',false,NULL,NULL),
('unidentified','care_days','insert',false,NULL,NULL),
('unidentified','care_days','update',false,NULL,NULL),
('unidentified','care_days','delete',false,NULL,NULL);

INSERT INTO access_matrix (actor, table_name, operation, allowed, condition, note)
SELECT a.actor, t.tbl, m.operation, m.allowed,
       CASE WHEN m.allowed THEN 'Follows the care day it belongs to' END,
       'Reached only through its care day, and never addressed directly by the application.'
FROM (VALUES ('care_day_meals'),('care_day_concerns')) AS t(tbl)
CROSS JOIN LATERAL (
  SELECT actor, operation, allowed
  FROM access_matrix
  WHERE table_name = 'care_days'
) AS m
JOIN (SELECT DISTINCT actor FROM access_matrix) a ON a.actor = m.actor
WHERE NOT (m.operation = 'delete' AND m.actor = 'retention');

-- Retention never deletes these directly: they cascade from the care day.
INSERT INTO access_matrix (actor, table_name, operation, allowed, condition, note) VALUES
('retention','care_day_meals','delete',false,NULL,'Cascades from care_days. The policy for this role is USING (false) on purpose.'),
('retention','care_day_concerns','delete',false,NULL,'As above.');

-- ── medication ─────────────────────────────────────────────────────────────────

INSERT INTO access_matrix (actor, table_name, operation, allowed, condition, note) VALUES
('caregiver','medication_events','select',true,'For residents assigned to them',NULL),
('caregiver','medication_events','insert',true,'Only with source = caregiver','A request cannot write a row attributed to a clinical system, so a stolen session cannot forge an entry a family would read as a MedTech record.'),
('caregiver','medication_events','update',false,NULL,'A medication event is a fact about a moment. It is not edited.'),
('caregiver','medication_events','delete',false,NULL,NULL),
('care_manager','medication_events','select',true,'Every event in their facility',NULL),
('care_manager','medication_events','insert',true,'Only with source = caregiver',NULL),
('care_manager','medication_events','update',false,NULL,NULL),
('care_manager','medication_events','delete',false,NULL,NULL),
('family','medication_events','select',true,'For the resident they hold a grant for',NULL),
('family','medication_events','insert',false,NULL,NULL),
('family','medication_events','update',false,NULL,NULL),
('family','medication_events','delete',false,NULL,NULL),
('integration','medication_events','select',false,NULL,NULL),
('integration','medication_events','insert',true,'Only with a source and a reference to the record it came from','The one thing this actor exists to do.'),
('integration','medication_events','update',false,NULL,NULL),
('integration','medication_events','delete',false,NULL,NULL),
('retention','medication_events','select',true,'Identifiers only. Not the status.',NULL),
('retention','medication_events','insert',false,NULL,NULL),
('retention','medication_events','update',false,NULL,NULL),
('retention','medication_events','delete',true,'Only events belonging to an expired resident',NULL),
('unidentified','medication_events','select',false,NULL,NULL),
('unidentified','medication_events','insert',false,NULL,NULL),
('unidentified','medication_events','update',false,NULL,NULL),
('unidentified','medication_events','delete',false,NULL,NULL);

-- ── photographs ────────────────────────────────────────────────────────────────

INSERT INTO access_matrix (actor, table_name, operation, allowed, condition, note) VALUES
('caregiver','media_objects','select',true,'Undeleted media for residents assigned to them','This row is what gates a signed URL. The link is minted after the policy admits the caller, never before.'),
('caregiver','media_objects','insert',true,'For residents assigned to them',NULL),
('caregiver','media_objects','update',false,NULL,NULL),
('caregiver','media_objects','delete',false,NULL,NULL),
('care_manager','media_objects','select',true,'Undeleted media in their facility',NULL),
('care_manager','media_objects','insert',true,'For residents in their facility',NULL),
('care_manager','media_objects','update',false,NULL,NULL),
('care_manager','media_objects','delete',false,NULL,NULL),
('family','media_objects','select',true,'Undeleted media for the resident they hold a grant for','An expired grant cannot be replayed by keeping an old link, because the link is minted per request.'),
('family','media_objects','insert',false,NULL,NULL),
('family','media_objects','update',false,NULL,NULL),
('family','media_objects','delete',false,NULL,NULL),
('integration','media_objects','select',false,NULL,NULL),
('integration','media_objects','insert',false,NULL,NULL),
('integration','media_objects','update',false,NULL,NULL),
('integration','media_objects','delete',false,NULL,NULL),
('retention','media_objects','select',true,'Identifiers, bucket and path only',NULL),
('retention','media_objects','insert',false,NULL,NULL),
('retention','media_objects','update',true,'To stamp an object as gone from storage, one way only','Null becoming a timestamp. A confirmation cannot be taken back.'),
('retention','media_objects','delete',true,'Only once storage has confirmed the object is gone','This is what makes the handshake real rather than a convention.'),
('unidentified','media_objects','select',false,NULL,NULL),
('unidentified','media_objects','insert',false,NULL,NULL),
('unidentified','media_objects','update',false,NULL,NULL),
('unidentified','media_objects','delete',false,NULL,NULL);

-- ── who may see a resident ─────────────────────────────────────────────────────

INSERT INTO access_matrix (actor, table_name, operation, allowed, condition, note) VALUES
('caregiver','resident_contacts','select',true,'Their own grants only','A caregiver is not shown a resident''s family list.'),
('caregiver','resident_contacts','insert',false,NULL,'A caregiver files care. They do not decide who in a family may read it.'),
('caregiver','resident_contacts','update',false,NULL,NULL),
('caregiver','resident_contacts','delete',false,NULL,NULL),
('care_manager','resident_contacts','select',true,'Every grant in their facility',NULL),
('care_manager','resident_contacts','insert',true,'In their facility',NULL),
('care_manager','resident_contacts','update',true,'In their facility','Which is how access is withdrawn: the row is revoked, not removed, so the trail survives.'),
('care_manager','resident_contacts','delete',false,NULL,NULL),
('family','resident_contacts','select',true,'Their own grants only','So the app can list which residents they are linked to.'),
('family','resident_contacts','insert',false,NULL,NULL),
('family','resident_contacts','update',false,NULL,NULL),
('family','resident_contacts','delete',false,NULL,NULL),
('integration','resident_contacts','select',false,NULL,NULL),
('integration','resident_contacts','insert',false,NULL,NULL),
('integration','resident_contacts','update',false,NULL,NULL),
('integration','resident_contacts','delete',false,NULL,NULL),
('retention','resident_contacts','select',true,'Identifiers only. Not the relation.',NULL),
('retention','resident_contacts','insert',false,NULL,NULL),
('retention','resident_contacts','update',false,NULL,NULL),
('retention','resident_contacts','delete',true,'Only grants belonging to an expired resident',NULL),
('unidentified','resident_contacts','select',false,NULL,NULL),
('unidentified','resident_contacts','insert',false,NULL,NULL),
('unidentified','resident_contacts','update',false,NULL,NULL),
('unidentified','resident_contacts','delete',false,NULL,NULL);

-- ── the trail ──────────────────────────────────────────────────────────────────

INSERT INTO access_matrix (actor, table_name, operation, allowed, condition, note)
SELECT a.actor, 'audit_events', o.op::access_operation,
       (a.actor IN ('caregiver','care_manager') AND o.op = 'select')
       OR (a.actor = 'retention' AND o.op IN ('select','delete')),
       CASE
         WHEN a.actor IN ('caregiver','care_manager') AND o.op = 'select'
           THEN 'Read only, and only through the application''s own query'
         WHEN a.actor = 'retention' AND o.op = 'select' THEN 'Facility and timestamp only'
         WHEN a.actor = 'retention' AND o.op = 'delete'
           THEN 'Only rows older than the facility''s audit window'
       END,
       CASE WHEN o.op IN ('insert','update') THEN
         'Revoked from the application entirely. An audit row appears only as a consequence of the thing it describes, so a compromised session cannot append a plausible history.'
       END
FROM (SELECT unnest(enum_range(NULL::access_actor)) AS actor) a
CROSS JOIN (SELECT unnest(ARRAY['select','insert','update','delete']) AS op) o;


-- ════════════════════════════════════════════════════════════════════ reading it

CREATE VIEW access_matrix_report AS
SELECT table_name, operation,
       max(CASE WHEN actor = 'caregiver'    THEN CASE WHEN allowed THEN condition ELSE '—' END END) AS caregiver,
       max(CASE WHEN actor = 'care_manager' THEN CASE WHEN allowed THEN condition ELSE '—' END END) AS care_manager,
       max(CASE WHEN actor = 'family'       THEN CASE WHEN allowed THEN condition ELSE '—' END END) AS family,
       max(CASE WHEN actor = 'integration'  THEN CASE WHEN allowed THEN condition ELSE '—' END END) AS integration,
       max(CASE WHEN actor = 'retention'    THEN CASE WHEN allowed THEN condition ELSE '—' END END) AS retention,
       max(CASE WHEN actor = 'unidentified' THEN CASE WHEN allowed THEN condition ELSE '—' END END) AS unidentified
FROM access_matrix GROUP BY table_name, operation
ORDER BY table_name, operation;

CREATE VIEW access_matrix_blanks AS
SELECT t.table_name, a.actor, o.operation
FROM (SELECT DISTINCT table_name FROM access_matrix) t
CROSS JOIN (SELECT unnest(enum_range(NULL::access_actor)) AS actor) a
CROSS JOIN (SELECT unnest(enum_range(NULL::access_operation)) AS operation) o
WHERE NOT EXISTS (SELECT 1 FROM access_matrix m
                  WHERE m.table_name = t.table_name AND m.actor = a.actor
                    AND m.operation = o.operation);

COMMENT ON VIEW access_matrix_blanks IS
  'Must be empty. A cell nobody filled in is a question nobody answered, and it is the one
   a reviewer will ask about.';


-- ════════════════════════════════════════════════════════════════════ against the catalogue
--
-- The matrix is a claim about the database. This is where the claim meets it.

CREATE VIEW access_matrix_delete_drift AS
-- Anything the catalogue permits to delete that the matrix does not describe as deletable.
SELECT p.tablename AS table_name, p.policyname, p.roles::text AS granted_to
FROM pg_policies p
WHERE p.schemaname = 'public'
  AND p.cmd IN ('DELETE', 'ALL')
  AND NOT EXISTS (
    SELECT 1 FROM access_matrix m
    WHERE m.table_name = p.tablename AND m.operation = 'delete' AND m.allowed
  );

COMMENT ON VIEW access_matrix_delete_drift IS
  'Must be empty. A DELETE policy appearing on a table the matrix says nothing can be
   deleted from is exactly the drift this file exists to catch.';

CREATE VIEW access_matrix_uncovered_tables AS
-- Tables holding PHI that the matrix says nothing about at all.
SELECT DISTINCT dc.table_name
FROM data_classification dc
JOIN information_schema.tables t
  ON t.table_schema = 'public' AND t.table_name = dc.table_name
 AND t.table_type = 'BASE TABLE'
WHERE dc.class = 'phi'
  AND dc.table_name NOT IN (SELECT table_name FROM access_matrix);

COMMENT ON VIEW access_matrix_uncovered_tables IS
  'Must be empty. A table acquires a PHI column in a later migration and nobody says who
   may read it; this is where that shows up.';
