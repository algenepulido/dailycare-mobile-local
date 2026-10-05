-- Who recorded a medication event, for somebody already allowed to read that resident.
--
-- The sibling of care_day_filed_by_name, and here for the same reason: a family member
-- cannot resolve recorded_by, because users is closed to them outside their own row. That is
-- right and stays right. The name is tied to the record instead.
--
-- It matters more here than it does on the day. A family reading "A.M, P.M" needs to know
-- whose statement it is, because the same two letters will mean something different when
-- PointClickCare feeds this table: a caregiver's tick is somebody saying they gave a dose,
-- and a clinical system's row is a record that one was administered. medication_source has
-- carried both values since the schema was written, and its comment says the family should
-- be able to see which they are reading. This is the half of that which was missing.
--
-- Only the caregiver's own rows have a name to give: an integration writes with recorded_by
-- null, by its own policy, so this returns null for one and the screen says where it came
-- from rather than who.
--
-- SECURITY DEFINER because the join has to see past the policies that hide users from a
-- family member; app_may_read_resident is the gate, and it is the same predicate the day
-- itself was served under, so this can disclose nothing the caller did not already have.
--
-- A new file because migrate.sh pins an applied one by digest. Correct against a database
-- built a moment ago and against one running since September: CREATE OR REPLACE either way,
-- and it reads tables that have existed since schema.sql.

CREATE OR REPLACE FUNCTION medication_recorded_by_name(target_event uuid) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = pg_catalog, public AS $$
  SELECT u.display_name
    FROM medication_events me
    JOIN users u ON u.id = me.recorded_by
   WHERE me.id = target_event
     AND app_may_read_resident(me.resident_id, me.facility_id)
$$;

COMMENT ON FUNCTION medication_recorded_by_name(uuid) IS
  'The display name of the caregiver who recorded one medication event, for a caller who may
   already read that resident. Null for an event from a clinical feed, which records no
   DailyCare user — the screen says where that came from instead of who.';
