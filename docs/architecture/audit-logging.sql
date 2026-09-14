-- Audit logging
--
-- Applied after access-policies.sql.
--
-- The design question is not what to record. It is what happens on the day a handler
-- forgets to record it — and an audit trail the application maintains by remembering is
-- one bad merge away from a gap nobody notices until a reviewer asks.
--
-- So writes are logged by the database. Every insert or update of a table holding PHI
-- fires a trigger, and there is no path through the application that writes to one of
-- those tables without producing an audit row. The application is not trusted to
-- remember, and it is not permitted to write audit rows by hand either: INSERT on
-- audit_events is revoked from the application role, and the only way a row appears is
-- as a consequence of the thing it describes.
--
-- Reads are the honest gap. PostgreSQL has no SELECT trigger, so a read is logged by the
-- application calling audit_read() on the one path that serves resident data. That is a
-- convention rather than a guarantee, it is the weakest part of this design, and it is
-- written down here rather than left for a reviewer to find.
--
-- What is recorded is which columns changed, never what they changed to. An audit log
-- that quotes the record it protects has become a second copy of it, with a longer
-- retention and usually a weaker one.


-- ════════════════════════════════════════════════════════════════════ the writer

CREATE OR REPLACE FUNCTION audit_phi_write() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  resident   uuid;
  facility   uuid;
  changed    text[];
  row_new    jsonb := to_jsonb(NEW);
  row_old    jsonb;
BEGIN
  -- Where the resident is, per table, passed in when the trigger is attached rather
  -- than guessed from the row.
  CASE TG_ARGV[0]
    WHEN 'self'         THEN resident := NEW.id;
    WHEN 'resident_id'  THEN resident := (row_new ->> 'resident_id')::uuid;
    WHEN 'via_care_day' THEN
      SELECT cd.resident_id, cd.facility_id INTO resident, facility
      FROM care_days cd WHERE cd.id = (row_new ->> 'care_day_id')::uuid;
    ELSE resident := NULL;
  END CASE;

  IF facility IS NULL THEN
    facility := nullif(row_new ->> 'facility_id', '')::uuid;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    row_old := to_jsonb(OLD);
    SELECT array_agg(k ORDER BY k) INTO changed
    FROM jsonb_object_keys(row_new) AS k
    WHERE row_new -> k IS DISTINCT FROM row_old -> k;

    -- An update that changed nothing is not worth a row.
    IF changed IS NULL THEN RETURN NEW; END IF;
  END IF;

  INSERT INTO audit_events (
    actor_user_id, actor_role, facility_id,
    action, subject_type, subject_id, resident_id,
    request_id, detail
  ) VALUES (
    nullif(current_setting('app.user_id',    true), '')::uuid,
    nullif(current_setting('app.role',       true), ''),
    facility,
    TG_TABLE_NAME || '.' || lower(TG_OP),
    TG_TABLE_NAME,
    (row_new ->> 'id')::uuid,
    resident,
    nullif(current_setting('app.request_id', true), ''),
    -- Column names only. Never a value from the row.
    CASE WHEN changed IS NULL THEN '{}'::jsonb
         ELSE jsonb_build_object('columns', to_jsonb(changed)) END
  );

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION audit_phi_write() IS
  'Runs as the definer so the application cannot be in a position to fail to write an
   audit row. Records which columns changed, never their contents.';


-- ════════════════════════════════════════════════════════════════════ attachments
--
-- Every table classified as holding PHI. If a table is added to that set later and not
-- given a trigger here, audit_coverage below reports it.

CREATE TRIGGER audit_residents
  AFTER INSERT OR UPDATE ON residents
  FOR EACH ROW EXECUTE FUNCTION audit_phi_write('self');

CREATE TRIGGER audit_care_days
  AFTER INSERT OR UPDATE ON care_days
  FOR EACH ROW EXECUTE FUNCTION audit_phi_write('resident_id');

CREATE TRIGGER audit_medication_events
  AFTER INSERT OR UPDATE ON medication_events
  FOR EACH ROW EXECUTE FUNCTION audit_phi_write('resident_id');

CREATE TRIGGER audit_media_objects
  AFTER INSERT OR UPDATE ON media_objects
  FOR EACH ROW EXECUTE FUNCTION audit_phi_write('resident_id');

CREATE TRIGGER audit_resident_contacts
  AFTER INSERT OR UPDATE ON resident_contacts
  FOR EACH ROW EXECUTE FUNCTION audit_phi_write('resident_id');

CREATE TRIGGER audit_care_day_meals
  AFTER INSERT OR UPDATE ON care_day_meals
  FOR EACH ROW EXECUTE FUNCTION audit_phi_write('via_care_day');

CREATE TRIGGER audit_care_day_concerns
  AFTER INSERT OR UPDATE ON care_day_concerns
  FOR EACH ROW EXECUTE FUNCTION audit_phi_write('via_care_day');


-- ════════════════════════════════════════════════════════════════════ reads

CREATE OR REPLACE FUNCTION audit_read(
  target_resident uuid,
  subject         text,
  target_subject  uuid DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  INSERT INTO audit_events (
    actor_user_id, actor_role, facility_id,
    action, subject_type, subject_id, resident_id, request_id
  )
  SELECT
    nullif(current_setting('app.user_id',    true), '')::uuid,
    nullif(current_setting('app.role',       true), ''),
    r.facility_id,
    subject || '.read',
    subject,
    target_subject,
    target_resident,
    nullif(current_setting('app.request_id', true), '')
  FROM residents r WHERE r.id = target_resident;
END;
$$;

COMMENT ON FUNCTION audit_read(uuid, text, uuid) IS
  'Called by the application on the single path that serves resident data to a client.
   PostgreSQL cannot trigger on SELECT, so unlike the write path this is a convention the
   code has to keep. It is the weakest guarantee in the audit design and is listed as such
   in the review package.';


-- ════════════════════════════════════════════════════════════════════ coverage
--
-- Which PHI-bearing tables have a write trigger and which do not. A table that acquires
-- a PHI column later, and no trigger, shows up here rather than in an incident.

CREATE VIEW audit_coverage AS
SELECT
  t.table_name,
  count(*) FILTER (WHERE dc.class = 'phi') AS phi_columns,
  EXISTS (
    SELECT 1 FROM pg_trigger tg
    JOIN pg_class c ON c.oid = tg.tgrelid
    WHERE c.relname = t.table_name
      AND NOT tg.tgisinternal
      AND tg.tgfoid = 'audit_phi_write'::regproc
  ) AS has_audit_trigger
FROM information_schema.tables t
JOIN data_classification dc ON dc.table_name = t.table_name
WHERE t.table_schema = 'public' AND t.table_type = 'BASE TABLE'
  -- The trail does not audit itself. A trigger here would recurse, and it would not buy
  -- anything: the application cannot insert, update or delete an audit row at all, so
  -- the integrity of this table comes from the revoked privileges below rather than from
  -- a record of changes that cannot happen.
  AND t.table_name <> 'audit_events'
GROUP BY t.table_name
HAVING count(*) FILTER (WHERE dc.class = 'phi') > 0
ORDER BY t.table_name;

CREATE VIEW audit_gaps AS
SELECT table_name, phi_columns FROM audit_coverage WHERE NOT has_audit_trigger;

COMMENT ON VIEW audit_gaps IS
  'Must be empty. A PHI-bearing table with no audit trigger is a table whose changes
   nobody can account for.';


-- ════════════════════════════════════════════════════════════════════ privileges
--
-- The application may cause audit rows and read them back. It may not write one, and it
-- may not alter or remove one — so a compromised session cannot cover its own tracks by
-- appending a plausible history or deleting an inconvenient one.

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dailycare_app') THEN
    REVOKE INSERT, UPDATE, DELETE ON audit_events FROM dailycare_app;
    GRANT  SELECT                  ON audit_events TO   dailycare_app;
    GRANT  EXECUTE ON FUNCTION audit_read(uuid, text, uuid) TO dailycare_app;
  END IF;
END $$;
