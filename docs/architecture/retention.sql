-- Retention and deletion
--
-- Applied after audit-logging.sql.
--
-- Three things make this harder than a scheduled DELETE.
--
-- The first is that a photograph lives in two places: a row in this database and an
-- object in a bucket. Removing the row is easy and wrong — it leaves the object behind,
-- unreferenced, in a bucket covered by a BAA, with nothing left that knows whose it was.
-- So media retention is a handshake: the database says what is due, the job removes the
-- objects from storage, and only then may the row go. A row whose object was never
-- confirmed gone stays due and is offered again on the next run, and it holds back its
-- resident's whole record until it is dealt with.
--
-- The second is that the audit trail has to outlive the record it describes. A care
-- record is deleted when the facility's window closes; the trail of who read it is kept
-- for years. That is why audit_events.resident_id is a bare uuid rather than a foreign
-- key — after retention it names someone who no longer exists, which is the correct
-- answer and not a dangling one.
--
-- The third is that deletion is the one operation nobody can undo, so it is the last
-- place to rely on a function being written correctly. What may be deleted is therefore
-- stated twice: once in the job below, and once as row-level security, independently, in
-- the same file. If the job asks to delete a resident who is still in the building, the
-- database removes nothing. The function decides when to run; the database decides what
-- it is allowed to touch.
--
-- Nothing here runs as the application. Retention is its own role, it cannot read a care
-- note, and the application cannot invoke it.


-- ════════════════════════════════════════════════════════════════════ the rule
--
-- One definition of "expired", used by the job and by the policies. Written once so the
-- two cannot drift apart into a function that deletes more than the policy permits, or a
-- policy that silently swallows rows the job believed it had removed.
--
-- Runs as the definer for the same reason the access helpers do: a policy on residents
-- that reads residents recurses, and the retention role is not permitted to read that
-- table by hand.

CREATE OR REPLACE FUNCTION retention_resident_expired(target_resident uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT EXISTS (
    SELECT 1
    FROM residents r
    JOIN retention_policies p ON p.facility_id = r.facility_id
    WHERE r.id = target_resident
      AND r.departed_on IS NOT NULL
      AND r.departed_on + p.care_record_days < current_date
  )
$$;

COMMENT ON FUNCTION retention_resident_expired(uuid) IS
  'A resident still in the building is never expired, however old their earliest record
   is. A facility with no retention policy has no expired residents, so a missing policy
   deletes nothing rather than defaulting to something nobody agreed to.';


-- ════════════════════════════════════════════════════════════════════ what is due
--
-- These two take an as_of so a care manager can ask what will be due next quarter. The
-- job itself does not: it runs at today, because today is the only date the policies
-- below will agree to, and a job that could delete at a date of its choosing would make
-- the second check worthless.

CREATE OR REPLACE FUNCTION retention_due_residents(
  target_facility uuid,
  as_of           date DEFAULT current_date
) RETURNS TABLE (resident_id uuid, departed_on date, days_past integer)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT r.id, r.departed_on, (as_of - r.departed_on) - p.care_record_days
  FROM residents r
  JOIN retention_policies p ON p.facility_id = r.facility_id
  WHERE r.facility_id = target_facility
    AND r.departed_on IS NOT NULL
    AND r.departed_on + p.care_record_days < as_of
  ORDER BY r.departed_on
$$;

CREATE OR REPLACE FUNCTION retention_due_media(
  target_facility uuid,
  as_of           date DEFAULT current_date
) RETURNS TABLE (media_id uuid, bucket text, object_path text, reason text)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT m.id, m.bucket, m.object_path,
         CASE WHEN retention_resident_expired(m.resident_id)
              THEN 'resident record expired'
              ELSE 'media window passed' END
  FROM media_objects m
  JOIN retention_policies p ON p.facility_id = m.facility_id
  WHERE m.facility_id = target_facility
    AND m.deleted_at IS NULL
    AND ( (m.created_at + make_interval(days => p.media_days))::date < as_of
       OR retention_resident_expired(m.resident_id) )
  ORDER BY m.created_at
$$;

COMMENT ON FUNCTION retention_due_media(uuid, date) IS
  'The job reads this, removes each object from the bucket, then calls
   retention_confirm_media with the ids it succeeded on. Anything it failed on stays due
   and is offered again — which is what keeps a bucket from quietly accumulating objects
   no row remembers.';


-- ════════════════════════════════════════════════════════════════════ the handshake

CREATE OR REPLACE FUNCTION retention_confirm_media(media_ids uuid[])
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE n integer;
BEGIN
  PERFORM set_config('app.role', 'retention', true);
  UPDATE media_objects SET deleted_at = now()
  WHERE id = ANY(media_ids) AND deleted_at IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END; $$;

COMMENT ON FUNCTION retention_confirm_media(uuid[]) IS
  'Records that the object is gone from storage. The row goes on the next apply_retention.
   The stamp is one-way: the update policy accepts a null becoming a timestamp and nothing
   else, so a confirmation cannot be taken back to make a deleted photograph look present.';


-- ════════════════════════════════════════════════════════════════════ the job

CREATE OR REPLACE FUNCTION apply_retention(target_facility uuid)
RETURNS TABLE (what text, removed bigint)
LANGUAGE plpgsql AS $$
DECLARE
  due         uuid[];
  held        bigint;
  policy_days integer;
  n           bigint;
  counts      jsonb := '{}'::jsonb;
BEGIN
  PERFORM set_config('app.role', 'retention', true);

  SELECT audit_days INTO policy_days
  FROM retention_policies WHERE facility_id = target_facility;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'no retention policy for facility %, refusing to guess one',
                    target_facility;
  END IF;

  -- Due, minus anyone whose photographs are still in the bucket. Deleting their rows
  -- would strand the objects, so the record waits for the next run.
  SELECT coalesce(array_agg(d.resident_id), '{}'::uuid[]) INTO due
  FROM retention_due_residents(target_facility) d
  WHERE NOT EXISTS (
    SELECT 1 FROM media_objects m
    WHERE m.resident_id = d.resident_id AND m.deleted_at IS NULL
  );

  SELECT count(*) INTO held FROM retention_due_media(target_facility)
  WHERE reason = 'resident record expired';

  -- Rows whose object storage has confirmed gone, due resident or not.
  DELETE FROM media_objects WHERE facility_id = target_facility AND deleted_at IS NOT NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  what := 'media rows'; removed := n; RETURN NEXT;
  counts := counts || jsonb_build_object('media_rows', n);

  what := 'records held back, awaiting storage deletion'; removed := held; RETURN NEXT;
  counts := counts || jsonb_build_object('held_for_media', held);

  DELETE FROM medication_events WHERE resident_id = ANY(due);
  GET DIAGNOSTICS n = ROW_COUNT;
  what := 'medication events'; removed := n; RETURN NEXT;
  counts := counts || jsonb_build_object('medication_events', n);

  -- Meals and concerns go with the day they belong to.
  DELETE FROM care_days WHERE resident_id = ANY(due);
  GET DIAGNOSTICS n = ROW_COUNT;
  what := 'care days'; removed := n; RETURN NEXT;
  counts := counts || jsonb_build_object('care_days', n);

  DELETE FROM resident_contacts WHERE resident_id = ANY(due);
  GET DIAGNOSTICS n = ROW_COUNT;
  what := 'family access rows'; removed := n; RETURN NEXT;
  counts := counts || jsonb_build_object('resident_contacts', n);

  DELETE FROM assignments WHERE resident_id = ANY(due);
  GET DIAGNOSTICS n = ROW_COUNT;
  what := 'assignments'; removed := n; RETURN NEXT;
  counts := counts || jsonb_build_object('assignments', n);

  DELETE FROM residents WHERE id = ANY(due);
  GET DIAGNOSTICS n = ROW_COUNT;
  what := 'residents'; removed := n; RETURN NEXT;
  counts := counts || jsonb_build_object('residents', n);

  -- The trail has its own window, measured from when the event happened rather than from
  -- anything about the resident. It is deliberately the last thing to go: the record of
  -- a deletion should outlive the deletion.
  DELETE FROM audit_events
  WHERE facility_id = target_facility
    AND occurred_at + make_interval(days => policy_days) < now();
  GET DIAGNOSTICS n = ROW_COUNT;
  what := 'audit events'; removed := n; RETURN NEXT;
  counts := counts || jsonb_build_object('audit_events', n);

  PERFORM retention_record_run(target_facility, counts);
  RETURN;
END; $$;

COMMENT ON FUNCTION apply_retention(uuid) IS
  'Refuses to run for a facility with no policy rather than falling back to a default
   nobody agreed to. Deletes nothing outside what the retention policies below permit,
   which is checked by the database rather than by this function.';


-- ════════════════════════════════════════════════════════════════════ the record of it
--
-- A reviewer asks two questions about retention, and the second one is the hard one:
-- is the old record gone, and can you show me that it went on schedule. Counts only —
-- naming the residents destroyed would rebuild, inside the audit trail, a list of exactly
-- the people whose records were supposed to have stopped existing.

CREATE OR REPLACE FUNCTION retention_record_run(target_facility uuid, counts jsonb)
RETURNS void LANGUAGE sql SECURITY DEFINER AS $$
  INSERT INTO audit_events (actor_user_id, actor_role, facility_id,
                            action, subject_type, subject_id, detail)
  VALUES (NULL, 'retention', target_facility,
          'retention.applied', 'facility', target_facility, counts)
$$;


-- ════════════════════════════════════════════════════════════════════ the role

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dailycare_retention') THEN
    CREATE ROLE dailycare_retention NOLOGIN;
  END IF;
END $$;

GRANT USAGE ON SCHEMA public TO dailycare_retention;

-- Deletion, and the bare minimum needed to aim it. The retention role can see which rows
-- are due and remove them; it cannot read a care note, a resident's name, or a
-- medication status. The columns it is granted are identifiers and dates.
GRANT SELECT (id, facility_id, resident_id, deleted_at), DELETE ON media_objects
  TO dailycare_retention;
GRANT UPDATE (deleted_at)                                ON media_objects
  TO dailycare_retention;
GRANT SELECT (id, facility_id),              DELETE ON residents         TO dailycare_retention;
GRANT SELECT (id, resident_id),              DELETE ON care_days         TO dailycare_retention;
GRANT SELECT (id, resident_id),              DELETE ON medication_events TO dailycare_retention;
GRANT SELECT (id, resident_id),              DELETE ON resident_contacts TO dailycare_retention;
GRANT SELECT (id, resident_id),              DELETE ON assignments       TO dailycare_retention;
GRANT SELECT (id, facility_id, occurred_at), DELETE ON audit_events      TO dailycare_retention;
GRANT SELECT ON retention_policies TO dailycare_retention;

GRANT EXECUTE ON FUNCTION apply_retention(uuid)                  TO dailycare_retention;
GRANT EXECUTE ON FUNCTION retention_confirm_media(uuid[])        TO dailycare_retention;
GRANT EXECUTE ON FUNCTION retention_due_media(uuid, date)        TO dailycare_retention;
GRANT EXECUTE ON FUNCTION retention_due_residents(uuid, date)    TO dailycare_retention;
GRANT EXECUTE ON FUNCTION retention_record_run(uuid, jsonb)      TO dailycare_retention;

-- Retention is not something a request can cause.
REVOKE EXECUTE ON FUNCTION apply_retention(uuid)            FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION retention_confirm_media(uuid[])  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION retention_record_run(uuid, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION retention_due_residents(uuid, date) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION retention_due_media(uuid, date)  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION retention_resident_expired(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION retention_resident_expired(uuid) TO dailycare_retention;


-- ════════════════════════════════════════════════════════════════════ what it may touch
--
-- The second statement of the rule. Every PHI table forces row-level security, so the
-- retention role reaches a row only through a policy written here — and every one of
-- these policies asks the same question the job asks, independently of the job.
--
-- These are the only DELETE policies in the model. The application has none, on any
-- table, for any role.

CREATE POLICY residents_retention_select ON residents FOR SELECT
  TO dailycare_retention USING (true);
CREATE POLICY residents_retention_delete ON residents FOR DELETE
  TO dailycare_retention USING (retention_resident_expired(id));

CREATE POLICY care_days_retention_select ON care_days FOR SELECT
  TO dailycare_retention USING (true);
CREATE POLICY care_days_retention_delete ON care_days FOR DELETE
  TO dailycare_retention USING (retention_resident_expired(resident_id));

CREATE POLICY care_day_meals_retention_delete ON care_day_meals FOR DELETE
  TO dailycare_retention USING (false);
CREATE POLICY care_day_concerns_retention_delete ON care_day_concerns FOR DELETE
  TO dailycare_retention USING (false);

CREATE POLICY medication_retention_select ON medication_events FOR SELECT
  TO dailycare_retention USING (true);
CREATE POLICY medication_retention_delete ON medication_events FOR DELETE
  TO dailycare_retention USING (retention_resident_expired(resident_id));

CREATE POLICY contacts_retention_select ON resident_contacts FOR SELECT
  TO dailycare_retention USING (true);
CREATE POLICY contacts_retention_delete ON resident_contacts FOR DELETE
  TO dailycare_retention USING (retention_resident_expired(resident_id));

CREATE POLICY media_retention_select ON media_objects FOR SELECT
  TO dailycare_retention USING (true);

-- A media row may only be removed once storage has confirmed the object is gone. This is
-- the constraint that makes the handshake real rather than a convention: a job that
-- deleted rows before emptying the bucket would remove nothing at all.
CREATE POLICY media_retention_delete ON media_objects FOR DELETE
  TO dailycare_retention USING (deleted_at IS NOT NULL);

-- And the stamp is one-way.
CREATE POLICY media_retention_confirm ON media_objects FOR UPDATE
  TO dailycare_retention
  USING (deleted_at IS NULL) WITH CHECK (deleted_at IS NOT NULL);

COMMENT ON POLICY care_day_meals_retention_delete ON care_day_meals IS
  'Never directly. Meals and concerns belong to a care day and go when it goes, by
   cascade, which the referential action performs rather than this role.';
