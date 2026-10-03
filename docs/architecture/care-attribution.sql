-- The name of whoever filed a day, for somebody already allowed to read that day.
--
-- A family member reads their resident's day and gets filed_by, which is a uuid and so is
-- nobody. The home's own weekly summary names the caregiver in every line of it - "with
-- Maria", "Maria wrote" - because telling a family who looked after their mother is the
-- product rather than a detail of it. So the name has to cross, and the only question is
-- how narrowly.
--
-- Not by widening users. users_colleagues is scoped to a shared facility and a family member
-- has none, which is right and stays right: a family should not be able to read a building's
-- staff list, and a policy that let them would be a rule about people rather than about a
-- record. This is tied to the record instead. It answers for one care day, only for a caller
-- who may already read that resident, and it returns a name and nothing else - no address,
-- no id, no row to join against.
--
-- SECURITY DEFINER because the joins have to see past the policies that hide users from a
-- family member; app_may_read_resident is the gate, and it is the same predicate the care
-- day itself was served under, so this can disclose nothing the caller did not already have.
-- No audit_read: the read of the resident was recorded when the day was fetched, in the same
-- transaction, and a second row for the name of the person who filed it would say nothing
-- the first does not.
--
-- A new file because migrate.sh pins an applied one by digest. Correct against a database
-- built a moment ago and against one running since September: CREATE OR REPLACE either way,
-- and it reads tables that have existed since schema.sql.

CREATE OR REPLACE FUNCTION care_day_filed_by_name(target_day uuid) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = pg_catalog, public AS $$
  SELECT u.display_name
    FROM care_days cd
    JOIN residents r ON r.id = cd.resident_id
    JOIN users     u ON u.id = cd.filed_by
   WHERE cd.id = target_day
     AND app_may_read_resident(cd.resident_id, r.facility_id)
$$;

COMMENT ON FUNCTION care_day_filed_by_name(uuid) IS
  'The display name of the caregiver who filed one day, for a caller who may already read
   that resident. Scoped to the record rather than to the person: it says who filed a day
   somebody is reading, and gives no way to ask about anybody else.';
