-- An assignment names a resident and a member of staff, and both belong to one building.
-- Nothing said the two had to be the same building.
--
-- assignments_manager_writes asks whether the caller manages the facility on the row. The
-- foreign key points at facility_members(id) alone, so any member of any building
-- satisfies it, and app_is_assigned joins the member without comparing their facility to
-- the assignment's. A care manager at Cedar could therefore hand a Cedar resident to a
-- Birch caregiver, and that caregiver could read and write her record.
--
-- Proved by an independent review rather than by this model, which is the part worth
-- recording: three separate places each checked one half of the pair and none checked that
-- the halves matched.
--
-- The application never managed it, but only by accident. facility.Assign inserts, reads
-- back, and does both in one transaction; the read-back joins facility_members and fails
-- under row security, so the transaction rolls back. The row never lands - and what the
-- caller sees is a 500. A control that works by crashing is not a control, and the comment
-- in facility.go claiming the policy refused this has been corrected alongside this file.
--
-- Three changes. The key makes it impossible, the function stops reading what the key now
-- forbids, and the guard below refuses to let either happen quietly over bad data.


-- ════════════════════════════════════════════════════════ refuse to run over bad rows
--
-- A foreign key applies to every row, ended or not, so a cross-building assignment cannot
-- be left in place by closing it - and it must not be deleted either. An assignment is the
-- record of who was given access to whom; destroying one to make a constraint apply would
-- remove the evidence of exactly the thing this file exists to stop.
--
-- So: if any exist, this stops and names them, and a person decides. None are expected -
-- the only route in was raw SQL - and if that turns out to be wrong, the finding is more
-- important than the migration.
DO $$
DECLARE wrong int;
BEGIN
  SELECT count(*) INTO wrong
    FROM assignments a
    JOIN facility_members fm ON fm.id = a.facility_member_id
   WHERE fm.facility_id <> a.facility_id;

  IF wrong > 0 THEN
    RAISE EXCEPTION
      'assignments: % row(s) name a member of a different building. These are disclosures '
      'that already happened; read them, decide what each one was, and record that before '
      'this runs: SELECT a.id, a.resident_id, a.facility_id, fm.facility_id AS member_facility '
      'FROM assignments a JOIN facility_members fm ON fm.id = a.facility_member_id '
      'WHERE fm.facility_id <> a.facility_id;', wrong;
  END IF;
END $$;


-- ════════════════════════════════════════════════════════════════════ the key
--
-- Redundant against the primary key and required anyway: a composite foreign key needs a
-- unique constraint covering exactly the columns it references.
ALTER TABLE facility_members
  ADD CONSTRAINT facility_members_id_facility_key UNIQUE (id, facility_id);

ALTER TABLE assignments
  ADD CONSTRAINT assignments_member_is_in_the_same_facility
  FOREIGN KEY (facility_member_id, facility_id)
  REFERENCES facility_members (id, facility_id) ON DELETE RESTRICT;

COMMENT ON CONSTRAINT assignments_member_is_in_the_same_facility ON assignments IS
  'The pair, not the two halves. facility_member_id already pointed at a real member and
   facility_id at a real building; this is what says they are the same building.';


-- ═══════════════════════════════════════════════════════════════ and the reader
--
-- The key stops new rows. This stops the ones that are already there being read, which
-- matters because the key is being added to a model that has been running.
CREATE OR REPLACE FUNCTION app_is_assigned(target_resident uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = pg_catalog, public AS $$
  SELECT EXISTS (
    SELECT 1
    FROM assignments a
    JOIN facility_members fm ON fm.id = a.facility_member_id
    WHERE fm.user_id      = app_user_id()
      AND a.resident_id   = target_resident
      AND a.ended_at   IS NULL
      AND fm.role         = 'caregiver'
      AND fm.state        = 'active'
      AND fm.ended_at  IS NULL
      -- The half that was missing.
      AND fm.facility_id  = a.facility_id
  )
$$;
