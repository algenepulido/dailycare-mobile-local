-- What capacity somebody was acting in, decided by the database rather than claimed.
--
-- The trail recorded actor_role from current_setting('app.role'), which the application
-- sets at the top of every transaction - and it set the literal string 'caregiver' for
-- every caller there has ever been. A care manager reading every record in a building was
-- written into the trail as a caregiver doing it. Access was never affected: that is
-- decided by app_is_care_manager() reading facility_members, and it was right the whole
-- time. What was wrong is the answer to "who did this, and as what", which is most of what
-- an audit trail is for.
--
-- Fixing the hardcoded string would have left the shape of the problem in place. The
-- application was telling the trail what role it was acting in and the trail believed it,
-- which is the same class of thing as the application writing its own audit rows - already
-- prevented, by revoking INSERT rather than by asking it not to. So the application no
-- longer gets a say: the role is read from the membership that grants the access, for the
-- facility the row belongs to, which is also the right granularity. Somebody who is a
-- caregiver in one building and a care manager in another is recorded correctly in each.
--
-- app.role still decides one case, and only one. A session with nobody in it is a job -
-- retention names itself before it stamps a photograph deleted, and that update is audited
-- like any other - and a job has no membership to read. So: a person's capacity is read
-- from the membership that grants it and their claim is ignored; a job with no person in
-- the session says what it is, because there is nothing else to ask. Written this way
-- after checking, not before: the first version read the membership unconditionally, which
-- would have turned retention's own audit rows from 'retention' into nothing at all.

CREATE OR REPLACE FUNCTION app_role_in(target_facility uuid) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = pg_catalog, public AS $$
  SELECT CASE WHEN app_user_id() IS NULL
    -- Nobody in the session, so this is a job and it may name itself.
    THEN nullif(current_setting('app.role', true), '')
    -- Somebody in the session, so the membership answers and the claim does not.
    -- care_manager first, so a person holding both roles in one building is recorded in
    -- the capacity that granted the wider access rather than whichever row came back.
    ELSE (SELECT fm.role::text
            FROM facility_members fm
           WHERE fm.user_id     = app_user_id()
             AND fm.facility_id = target_facility
             AND fm.state       = 'active'
             AND fm.ended_at IS NULL
           ORDER BY (fm.role = 'care_manager') DESC
           LIMIT 1)
  END
$$;

COMMENT ON FUNCTION app_role_in(uuid) IS
  'The capacity the acting user holds in one facility, for the audit trail. Null when they
   hold none - a family contact has no membership - which is a truer answer than naming a
   role they do not have.';

-- Both writers, replaced only in the line that decided actor_role. Everything else is the
-- text as it stands in audit-logging.sql.

CREATE OR REPLACE FUNCTION audit_phi_write() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, public AS $$
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
    app_role_in(facility),
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

CREATE OR REPLACE FUNCTION audit_read(
  target_resident uuid,
  subject         text,
  target_subject  uuid DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, public AS $$
DECLARE
  target_facility uuid;
BEGIN
  -- Two checks that were not here, and their absence undid the privilege model above.
  -- This function runs as the definer and is granted to the application, so without them
  -- it is the hole in "the application cannot write an audit row": a caller could record a
  -- read of a resident they cannot see, with free text that became the action.
  SELECT r.facility_id INTO target_facility FROM residents r WHERE r.id = target_resident;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'no such resident' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT app_may_read_resident(target_resident, target_facility) THEN
    RAISE EXCEPTION 'cannot record a read of a resident this session cannot read'
      USING ERRCODE = 'insufficient_privilege',
            HINT = 'The trail is not a place to assert something the access model would refuse.';
  END IF;

  -- The subject is a table name, not a sentence. Without this the action column takes
  -- whatever the caller sends, and the trail carries text nobody wrote a policy about.
  IF NOT EXISTS (SELECT 1 FROM data_classification dc WHERE dc.table_name = subject) THEN
    RAISE EXCEPTION 'unknown subject %', subject
      USING ERRCODE = 'check_violation',
            HINT = 'The subject names a table the classification knows about.';
  END IF;

  INSERT INTO audit_events (
    actor_user_id, actor_role, facility_id,
    action, subject_type, subject_id, resident_id, request_id
  )
  SELECT
    nullif(current_setting('app.user_id',    true), '')::uuid,
    app_role_in(target_facility),
    target_facility,
    subject || '.read',
    subject,
    target_subject,
    target_resident,
    nullif(current_setting('app.request_id', true), '');
END;
$$;
