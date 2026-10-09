-- A photograph of the resident, rather than of their day.
--
-- The family screen draws an initial in a circle because there has never been anything
-- else to draw. A face is what makes an app about somebody's mother feel like it is about
-- somebody's mother, and it was asked for.
--
-- Nothing new is needed to hold it. media_objects already takes a photograph with no day
-- against it - care_day_id is nullable and the pair is MATCH SIMPLE precisely so that is
-- allowed - and the row carries resident_id and facility_id itself, with the composite key
-- that ties them together and the path prefix that ties the object to the building. So a
-- resident's photograph is a media object of theirs that belongs to no particular day.
--
-- Deliberately not a column on residents pointing at it. That was the first design, and it
-- recreates the shape this model was fixing the same week: two halves held separately and
-- the pair unchecked, so residents.photo_media_id could name another resident's object and
-- a care manager would have put somebody else's face on the record. There is no pair here
-- to get wrong. The row says whose it is, and that is the only statement there is.
--
-- Who may put one there is already answered: media_write asks app_may_write_resident, so a
-- care manager at the building or a caregiver assigned to the resident, and the uploader is
-- pinned to the requester. Who may see it is already answered too: media_read asks
-- app_may_read_resident, which is the same question the family's screen passes to read the
-- day at all. Neither needed changing, and neither was changed.


-- ═══════════════════════════════════════════════════════════════════ which one
--
-- Replacing a photograph is uploading another one, because the application cannot delete a
-- media row and should not be able to - deleting is the retention handshake's, and a row
-- that claims its object is gone when it is not is the thing media_write already refuses.
-- So there can be several, and the current one is the last that actually arrived.
--
-- uploaded_at rather than created_at, because a row is written before the object exists and
-- a phone that lost signal in between leaves one that never arrived. media_never_arrived is
-- the view that lists those; this is the function that does not count them.
--
-- SECURITY INVOKER, which is the default and is the point: it runs as the caller, so
-- media_read decides what it can see. A caller who may not read the resident gets nothing
-- back rather than an id they could not have found another way.
CREATE OR REPLACE FUNCTION resident_photograph(target_resident uuid)
RETURNS uuid LANGUAGE sql STABLE
  SET search_path = pg_catalog, public AS $$
  SELECT id
    FROM media_objects
   WHERE resident_id   = target_resident
     AND care_day_id  IS NULL
     AND uploaded_at IS NOT NULL
     AND deleted_at  IS NULL
   ORDER BY uploaded_at DESC
   LIMIT 1
$$;

COMMENT ON FUNCTION resident_photograph(uuid) IS
  'The resident''s own photograph, or nothing. Runs as the caller on purpose, so it answers
   only for somebody who may read that resident - the rule for which object it is lives
   here, and the rule for who may see it stays where it already was.';

GRANT EXECUTE ON FUNCTION resident_photograph(uuid) TO dailycare_app;


-- The index the function reads through. Partial, because the rows it never looks at are the
-- day photographs, which outnumber these by however many days a resident has been here.
CREATE INDEX IF NOT EXISTS media_resident_photograph
  ON media_objects (resident_id, uploaded_at DESC)
  WHERE care_day_id IS NULL AND uploaded_at IS NOT NULL AND deleted_at IS NULL;
