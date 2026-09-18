-- What the application is granted
--
-- Applied last, after every table exists.
--
-- No file in the model granted dailycare_app anything on any table. The only grants were
-- in the check suites, and they were GRANT SELECT, INSERT, UPDATE ON ALL TABLES - a test
-- scaffold. So the model did not say what the application may touch, and the first
-- deployment would have said it, in a migration nobody reviewed here.
--
-- It is a table for the same reason the access matrix is: a list in a migration is a list
-- nobody compares to anything. grant_drift compares this to the catalogue in both
-- directions, so a privilege granted by hand and a privilege declared and never applied
-- are both findings rather than surprises.
--
-- Row-level security decides which rows. This decides which tables and which columns, and
-- the two are different questions - a policy cannot stop an UPDATE touching a column, as
-- care_days found out.

CREATE TABLE app_privileges (
  grantee     text NOT NULL,
  table_name  text NOT NULL,
  privilege   text NOT NULL CHECK (privilege IN ('SELECT','INSERT','UPDATE','DELETE')),
  columns     text[],          -- null means every column
  note        text,
  PRIMARY KEY (grantee, table_name, privilege)
);

COMMENT ON COLUMN app_privileges.columns IS
  'Null is every column, which is the common case for SELECT. Where it is a list, the list
   is the point: UPDATE on care_days is superseded_at and nothing else, because a filed day
   is amended by adding and the only change it ever takes is being retired.';


-- ── what a request may read ────────────────────────────────────────────────────
--
-- Views are in here too. A view in PostgreSQL 14 runs with its owner's privileges, so a
-- view granted to the application is a way past every grant below it - which is how
-- session_inventory, a view listing every user's sessions, came to be readable by the
-- application while sessions itself was not.

INSERT INTO app_privileges (grantee, table_name, privilege, columns, note)
SELECT 'dailycare_app', t, 'SELECT', NULL, NULL
FROM unnest(ARRAY[
  'residents','care_days','care_day_meals','care_day_concerns','medication_events',
  'media_objects','resident_contacts','imported_content','content_responses',
  'users','facility_members','assignments','facilities','sessions',
  'retention_policies','audit_events','deployment','boundary_channels',
  'notification_templates','monitoring_signals',
  -- Views. never_log is a list of field names and holds nothing about anybody.
  'never_log'
]) AS t;

-- ── and what it may write ──────────────────────────────────────────────────────

INSERT INTO app_privileges (grantee, table_name, privilege, columns, note)
SELECT 'dailycare_app', t, 'INSERT', NULL, NULL
FROM unnest(ARRAY[
  'residents','care_days','care_day_meals','care_day_concerns','medication_events',
  'media_objects','resident_contacts','imported_content','content_responses'
]) AS t;

INSERT INTO app_privileges (grantee, table_name, privilege, columns, note) VALUES
('dailycare_app','care_days','UPDATE', ARRAY['superseded_at'],
 'The whole of what update is for on a filed day. A trigger refuses the rest; this means the request never gets that far.'),
('dailycare_app','residents','UPDATE',
 ARRAY['display_name','external_source','external_patient_id','baseline_mood',
       'baseline_appetite','baseline_sleep','admitted_on','departed_on','updated_at'],
 'A correction, a match to a clinical system, a departure. Not facility_id: a resident does not move buildings by an update.'),
('dailycare_app','resident_contacts','UPDATE',
 ARRAY['state','revoked_by','revoked_at','granted_by','granted_at','updated_at'],
 'Access is withdrawn by revoking the row. Not the resident it is for, and not the person it is for.'),
('dailycare_app','assignments','UPDATE', ARRAY['ended_at'],
 'An assignment ends. It does not move to another resident.'),
('dailycare_app','users','UPDATE', ARRAY['display_name','updated_at'],
 'A person corrects their own name. Not their email, which is their login, and not deactivated_at, which is an administrative act.'),
('dailycare_app','care_day_meals','UPDATE', ARRAY['happened','amount'],
 'While a day is being filed. A corrected day gets its own children.'),
('dailycare_app','media_objects','UPDATE', ARRAY['checksum'],
 'Set once the object is stored. Never deleted_at, which belongs to the retention handshake.');

-- Nothing anywhere grants the application DELETE. That is not an omission, and the check
-- below is what keeps it from becoming one.


-- ════════════════════════════════════════════════════════════════════ applying it

CREATE OR REPLACE FUNCTION apply_app_privileges() RETURNS integer
LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
DECLARE r record; n integer := 0;
BEGIN
  FOR r IN SELECT * FROM app_privileges WHERE EXISTS (
             SELECT 1 FROM pg_roles WHERE rolname = app_privileges.grantee)
  LOOP
    IF r.columns IS NULL THEN
      EXECUTE format('GRANT %s ON %I TO %I', r.privilege, r.table_name, r.grantee);
    ELSE
      EXECUTE format('GRANT %s (%s) ON %I TO %I', r.privilege,
                     (SELECT string_agg(quote_ident(c), ', ') FROM unnest(r.columns) c),
                     r.table_name, r.grantee);
    END IF;
    n := n + 1;
  END LOOP;
  RETURN n;
END; $$;

COMMENT ON FUNCTION apply_app_privileges() IS
  'The grants are applied from the table rather than written beside it, so the two cannot
   be different. A migration that adds a privilege adds a row.';

SELECT apply_app_privileges();


-- ════════════════════════════════════════════════════════════════════ the questions

-- Both kinds of grant, because a column-level one does not appear in role_table_grants at
-- all - which the first draft of this view got wrong, and reported seven privileges as
-- missing that were there.
CREATE VIEW app_effective_grants AS
SELECT g.grantee, g.table_name, g.privilege_type AS privilege
FROM information_schema.role_table_grants g
WHERE g.table_schema = 'public'
UNION
SELECT c.grantee, c.table_name, c.privilege_type
FROM information_schema.role_column_grants c
WHERE c.table_schema = 'public';

CREATE VIEW grant_drift AS
SELECT 'granted, not declared' AS direction, g.grantee, g.table_name, g.privilege
FROM app_effective_grants g
WHERE g.grantee IN (SELECT DISTINCT grantee FROM app_privileges)
  AND NOT EXISTS (
    SELECT 1 FROM app_privileges p
    WHERE p.grantee = g.grantee AND p.table_name = g.table_name
      AND p.privilege = g.privilege)
UNION ALL
SELECT 'declared, not granted', p.grantee, p.table_name, p.privilege
FROM app_privileges p
WHERE EXISTS (SELECT 1 FROM pg_roles WHERE rolname = p.grantee)
  AND NOT EXISTS (
    SELECT 1 FROM app_effective_grants g
    WHERE g.grantee = p.grantee AND g.table_name = p.table_name
      AND g.privilege = p.privilege);

COMMENT ON VIEW grant_drift IS
  'Must be empty, in both directions. One says somebody granted a privilege by hand; the
   other says a privilege was written down and never applied, which reads as a control and
   is not one.';

CREATE VIEW app_can_delete AS
SELECT g.grantee, g.table_name
FROM information_schema.role_table_grants g
WHERE g.table_schema = 'public'
  AND g.grantee = 'dailycare_app'
  AND g.privilege_type = 'DELETE';

COMMENT ON VIEW app_can_delete IS
  'Must be empty. A care record is retired by policy and destroyed by retention, and the
   application is not part of either.';

CREATE VIEW app_owns_something AS
SELECT c.relname AS object, c.relkind::text AS kind
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_roles r ON r.oid = c.relowner
WHERE n.nspname = 'public' AND r.rolname IN (SELECT DISTINCT grantee FROM app_privileges);

COMMENT ON VIEW app_owns_something IS
  'Must be empty, and it is what FORCE ROW LEVEL SECURITY was standing in for on the PHI
   tables. The identity tables are ENABLE rather than FORCE because a forced policy that
   consults a helper reading its own table recurses; this asks the question FORCE was
   guarding against directly, which is the better check - it looks rather than assumes.';

CREATE VIEW app_reaches_the_register AS
-- The compliance tables are not application data. This is the list of them it can see.
SELECT g.table_name, g.privilege_type AS privilege
FROM information_schema.role_table_grants g
WHERE g.table_schema = 'public' AND g.grantee = 'dailycare_app'
  AND g.table_name IN ('vendors','vendor_exposure','backup_policies','restore_drills',
                       'secrets_inventory','encryption_controls','scrub_rules','scrub_runs',
                       'access_matrix','app_privileges','integration_salts',
                       'boundary_fields','outbound_signals','user_tokens',
                       'security_incidents','breach_notifications');

COMMENT ON VIEW app_reaches_the_register IS
  'Must be empty. A register the application can read is a register a compromised session
   can read, and these are the files that say where the secrets are and who has not signed
   an agreement.';


-- ════════════════════════════════════════════════════════════════════ classification

INSERT INTO data_classification (table_name, column_name, class, note) VALUES
 ('app_privileges','grantee','operational',NULL),
 ('app_privileges','table_name','operational',NULL),
 ('app_privileges','privilege','operational',NULL),
 ('app_privileges','columns','operational',NULL),
 ('app_privileges','note','operational',NULL);


-- ════════════════════════════════════════════════════════════════════ the agreements
--
-- Classified here rather than in agreements.sql, which is applied before the
-- classification table exists. An agreement is a contract between two companies. The counterparty is a person who
-- signed on the facility's behalf, and the notification contact is who to call at four in
-- the morning - both identify somebody, neither is about a resident.

INSERT INTO data_classification (table_name, column_name, class, note) VALUES
 ('facility_agreements','id','operational',NULL),
 ('facility_agreements','facility_id','operational',NULL),
 ('facility_agreements','executed_on','operational',NULL),
 ('facility_agreements','terminated_on','operational',NULL),
 ('facility_agreements','notification_contact','identifying','A person to reach at the facility when a breach has to be reported.'),
 ('facility_agreements','notification_days','operational',NULL),
 ('facility_agreements','counterparty','identifying','Who signed, on the facility''s side.'),
 ('facility_agreements','note','operational',NULL);

INSERT INTO scrub_rules (table_name, column_name, strategy, reason) VALUES
 ('facility_agreements','notification_contact','redact_text',NULL),
 ('facility_agreements','counterparty','synthetic_name',NULL);

-- The matrix: nobody touches the agreements through the application. They are executed by
-- people and recorded by an operator, and the application only ever asks whether one
-- exists - through facility_is_covered(), which is a function rather than a grant.
INSERT INTO access_matrix (actor, table_name, operation, allowed, condition, note)
SELECT a.actor, 'facility_agreements', o.op::access_operation, false, NULL,
       'Not application data. The one question a request asks of it - is this facility covered - is answered by a definer function, so the answer is available and the contract is not.'
FROM (SELECT unnest(enum_range(NULL::access_actor)) AS actor) a
CROSS JOIN (SELECT unnest(ARRAY['select','insert','update','delete']) AS op) o;


-- ════════════════════════════════════════════════════════════════════ incidents
--
-- What happened and who was told. Deliberately says nothing about a resident: the summary
-- is what happened in words, never what the record said, and the constraint on
-- carries_phi refuses a row that claims otherwise.

INSERT INTO data_classification (table_name, column_name, class, note)
SELECT 'security_incidents', c.column_name, 'operational', NULL
FROM information_schema.columns c
WHERE c.table_schema = 'public' AND c.table_name = 'security_incidents'
  AND c.column_name <> 'discovered_by';
INSERT INTO data_classification (table_name, column_name, class, note) VALUES
 ('security_incidents','discovered_by','identifying','Who found it. A person, and staff rather than a patient.');

INSERT INTO data_classification (table_name, column_name, class, note)
SELECT 'breach_notifications', c.column_name, 'operational', NULL
FROM information_schema.columns c
WHERE c.table_schema = 'public' AND c.table_name = 'breach_notifications'
  AND c.column_name <> 'notified_whom';
INSERT INTO data_classification (table_name, column_name, class, note) VALUES
 ('breach_notifications','notified_whom','identifying','The contact at the facility, as it was at the time.');

INSERT INTO scrub_rules (table_name, column_name, strategy, reason) VALUES
 ('security_incidents','discovered_by','synthetic_name',NULL),
 ('breach_notifications','notified_whom','redact_text',NULL);

INSERT INTO access_matrix (actor, table_name, operation, allowed, condition, note)
SELECT a.actor, t.tbl, o.op::access_operation, false, NULL,
       'Not application data. An incident is recorded by the people handling it, and a request has no reason to read the register of what has gone wrong across every customer.'
FROM (SELECT unnest(enum_range(NULL::access_actor)) AS actor) a
CROSS JOIN (VALUES ('security_incidents'),('breach_notifications')) AS t(tbl)
CROSS JOIN (SELECT unnest(ARRAY['select','insert','update','delete']) AS op) o;


-- ════════════════════════════════════════════════════════════════════ the basis

INSERT INTO data_classification (table_name, column_name, class, note) VALUES
 ('deidentification_basis','only_row','operational',NULL),
 ('deidentification_basis','method','operational',NULL),
 ('deidentification_basis','determined_by','identifying','The qualified person who signed it.'),
 ('deidentification_basis','determined_on','operational',NULL),
 ('deidentification_basis','note','operational',NULL);

INSERT INTO scrub_rules (table_name, column_name, strategy, reason) VALUES
 ('deidentification_basis','determined_by','keep','A professional''s name on a determination about the data, which is not data about a resident and is what makes the determination traceable.');

INSERT INTO access_matrix (actor, table_name, operation, allowed, condition, note)
SELECT a.actor, 'deidentification_basis', o.op::access_operation, false, NULL,
       'Not application data. A statement about what a copy of this database is, signed by somebody, and nothing a request has business reading or changing.'
FROM (SELECT unnest(enum_range(NULL::access_actor)) AS actor) a
CROSS JOIN (SELECT unnest(ARRAY['select','insert','update','delete']) AS op) o;
