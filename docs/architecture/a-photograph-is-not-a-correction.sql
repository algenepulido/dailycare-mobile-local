-- What a new version of a day actually changed.
--
-- A caregiver who files at noon and comes back at four with a photograph has to send the
-- day again, because a photograph belongs to the version it arrives with. The record does
-- the right thing: a new version, the old one superseded, the whole chain readable. What
-- the family is then told is wrong. They read "this was updated after it was first
-- written" over a day where nothing about the care changed and a picture joined it.
--
-- That sentence is the one thing a care record must not get wrong in that direction. A
-- family reading that an entry was updated has been told the home changed its account of
-- their mother's day. Telling them that when it did not happen is worse than saying
-- nothing, and they have no way to check.
--
-- So: amends_id already says a version replaced another. This says what was different
-- about it.


-- ═══════════════════════════════════════════════════════════ what belongs to a version
--
-- Three things, and only three. care_days carries what was observed - mood, appetite,
-- sleep, the note and the two hygiene marks. care_day_meals and care_day_concerns hang off
-- a care_days row by id, so each version has its own.
--
-- Medication is deliberately not here. medication_events is keyed by resident and care
-- date rather than by a care_days row, which is the model saying that a dose is its own
-- record and does not belong to anybody's version of the day. "Maria Santos recorded this"
-- stays with Maria after Tomas corrects the day around it. Comparing it would make a
-- correction look like it had changed something it cannot reach.
--
-- A photograph is not compared either, for the opposite reason: it is the thing that is
-- left when nothing else differs. Rather than go looking for one, the answer is what the
-- care did, and 'photograph' is the name for a version that changed none of it. If some
-- later version of this product can change something else without touching the care, this
-- function will call that a photograph and be wrong, which is why the name of the thing it
-- returns is checked rather than assumed - see access-invariants.sql.
--
-- SECURITY INVOKER, the default, same as resident_photograph. It runs as the caller, so
-- care_days_read decides what it can see. That matters more here than it looks: the
-- previous version is a superseded row, and the read policy is app_may_read_resident with
-- no clause about superseded_at, so a family member can reach it and gets the same answer
-- as a care manager. If that policy ever grows such a clause, this function starts
-- answering 'photograph' to families for days that really were corrected - so the suite
-- asks it as a family member, not only as staff.
CREATE OR REPLACE FUNCTION care_day_amended_with(target uuid)
RETURNS text LANGUAGE sql STABLE
  SET search_path = pg_catalog, public AS $$
  WITH this AS (
    SELECT id, amends_id, mood, appetite, sleep, note, hygiene_shower, hygiene_grooming
      FROM care_days WHERE id = target
  ),
  before AS (
    SELECT c.id, c.mood, c.appetite, c.sleep, c.note, c.hygiene_shower, c.hygiene_grooming
      FROM care_days c JOIN this t ON c.id = t.amends_id
  )
  SELECT CASE
    -- Filed once, or the version it amends is not readable. Nothing to say either way.
    WHEN NOT EXISTS (SELECT 1 FROM before) THEN NULL

    WHEN (SELECT (mood, appetite, sleep, note, hygiene_shower, hygiene_grooming) FROM this)
         IS DISTINCT FROM
         (SELECT (mood, appetite, sleep, note, hygiene_shower, hygiene_grooming) FROM before)
      THEN 'care'

    -- The meals, as a set. A meal with no tick and a meal that is absent are the same
    -- statement - nobody wrote it down - so the comparison is over what is recorded rather
    -- than over three fixed slots.
    WHEN (SELECT count(*) FROM (
            SELECT slot, happened, amount FROM care_day_meals
             WHERE care_day_id = (SELECT id FROM this)
            EXCEPT ALL
            SELECT slot, happened, amount FROM care_day_meals
             WHERE care_day_id = (SELECT id FROM before)) d) > 0
      OR (SELECT count(*) FROM (
            SELECT slot, happened, amount FROM care_day_meals
             WHERE care_day_id = (SELECT id FROM before)
            EXCEPT ALL
            SELECT slot, happened, amount FROM care_day_meals
             WHERE care_day_id = (SELECT id FROM this)) d) > 0
      THEN 'care'

    WHEN (SELECT count(*) FROM (
            SELECT concern FROM care_day_concerns
             WHERE care_day_id = (SELECT id FROM this)
            EXCEPT ALL
            SELECT concern FROM care_day_concerns
             WHERE care_day_id = (SELECT id FROM before)) d) > 0
      OR (SELECT count(*) FROM (
            SELECT concern FROM care_day_concerns
             WHERE care_day_id = (SELECT id FROM before)
            EXCEPT ALL
            SELECT concern FROM care_day_concerns
             WHERE care_day_id = (SELECT id FROM this)) d) > 0
      THEN 'care'

    ELSE 'photograph'
  END
$$;

COMMENT ON FUNCTION care_day_amended_with(uuid) IS
  'What a version of a day changed when it replaced an earlier one: care, photograph, or
   nothing when it replaced nothing. Runs as the caller, so it answers only for somebody
   who may read that resident. Medication is not compared on purpose - it is keyed by
   resident and date rather than by a version, so a correction cannot reach it.';

GRANT EXECUTE ON FUNCTION care_day_amended_with(uuid) TO dailycare_app;
