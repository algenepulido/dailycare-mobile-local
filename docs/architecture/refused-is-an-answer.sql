-- A meal she would not eat, told apart from a meal nobody wrote down.
--
-- care_day_meals has held one boolean since the first milestone, and the product has been
-- careful about what it means: happened = false is "not recorded", never "not done". That
-- rule is in familyDay's comments, on the family's screen, on the caregiver's review sheet
-- and in the week's wording, because nobody wrote it down and she did not eat are different
-- claims and only one of them is in the record.
--
-- The design work settles the other half of it. A caregiver can now say that she refused,
-- and that is a third answer rather than a shade of the first two. A refused lunch is a
-- care fact: it is the thing a family would want to know and the thing a home would want
-- to have recorded. An unrecorded one is the absence of a fact.
--
-- So the record has to hold three states where it held two.


-- ═══════════════════════════════════════════════════════════════ why a column, not an enum
--
-- The tidier shape is one column with three values and no illegal combination to guard.
-- It was not chosen, and the reason is worth writing down rather than rediscovering.
--
-- Replacing happened means dropping a classified PHI column from a table that holds care
-- records, rewriting every row in it, and moving its classification row, its scrub rule,
-- its fixtures in six suites and the comparison in care_day_amended_with. All of that to a
-- table whose contents are somebody's mother's meals. The migration that does the least to
-- a care record is the one to prefer when both reach the same place.
--
-- What the second column must not become is the shape this model has already been caught
-- by once: two halves held separately with the pair unchecked. Here the pair is checked.
-- Eaten and refused cannot both be true, and the database refuses the row rather than
-- leaving a screen to decide which of the two it believes.
ALTER TABLE care_day_meals
  ADD COLUMN IF NOT EXISTS refused boolean NOT NULL DEFAULT false;

-- Three states, named by what is true:
--   happened = false, refused = false  nobody wrote it down
--   happened = true                    she ate, amount optional
--   refused  = true                    she would not eat
--
-- Existing rows take refused = false, which is already correct for every one of them: they
-- were written when refusing could not be said, so none of them is a refusal that was
-- recorded as something else.
ALTER TABLE care_day_meals
  DROP CONSTRAINT IF EXISTS care_day_meals_answer_is_one_answer;
ALTER TABLE care_day_meals
  ADD CONSTRAINT care_day_meals_answer_is_one_answer
  CHECK (NOT (happened AND refused));

-- An amount belongs to a meal she ate. The existing constraint says that about happened;
-- this says it about refused, so a refusal cannot arrive carrying how much of it she had.
ALTER TABLE care_day_meals
  DROP CONSTRAINT IF EXISTS care_day_meals_refused_has_no_amount;
ALTER TABLE care_day_meals
  ADD CONSTRAINT care_day_meals_refused_has_no_amount
  CHECK (NOT (refused AND amount IS NOT NULL));

COMMENT ON COLUMN care_day_meals.refused IS
  'She would not eat it. Distinct from happened = false, which is nobody wrote it down -
   the first is a care fact and the second is the absence of one. The two cannot both be
   true.';


-- ═════════════════════════════════════════════════════════ what the new column has to say
--
-- Every column in the schema has to be classified, and the unclassified_columns view is
-- what catches one that is not. A meal somebody refused is as much a statement about a
-- person's health as a meal they ate.
INSERT INTO data_classification (table_name, column_name, class, note) VALUES
  ('care_day_meals','refused','phi','Whether a person would not eat.')
ON CONFLICT (table_name, column_name) DO UPDATE
  SET class = EXCLUDED.class, note = EXCLUDED.note;

-- And a rule for what happens to it in a development copy. Kept, for the same reason the
-- other two are: a boolean with no name attached, and the behaviour around it is exactly
-- what a copy has to be testable against. A scrubbed copy where nobody ever refused a meal
-- would hide the wording this column exists to drive.
INSERT INTO scrub_rules (table_name, column_name, strategy, reason) VALUES
  ('care_day_meals','refused','keep',
   'A boolean with no name attached, and the three-state wording the app has to be tested against.')
ON CONFLICT (table_name, column_name) DO UPDATE
  SET strategy = EXCLUDED.strategy, reason = EXCLUDED.reason;


-- ═══════════════════════════════════════════ the comparison that has to see the new answer
--
-- care_day_amended_with decides whether a new version of a day changed the care or only
-- gained a photograph, and it compares the meals as a set of slot, happened and amount. A
-- third answer that it cannot see is a third answer it treats as no change: a caregiver
-- correcting "nobody wrote lunch down" to "she would not eat it" would have been told, on
-- her family's screen, that a photo was added. That is the exact sentence the function was
-- written to stop being wrong, pointed the other way.
--
-- Recreated here rather than edited where it was written, because a migration that has been
-- applied is a file that does not change. Everything else about it is as it was.
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
    WHEN NOT EXISTS (SELECT 1 FROM before) THEN NULL

    WHEN (SELECT (mood, appetite, sleep, note, hygiene_shower, hygiene_grooming) FROM this)
         IS DISTINCT FROM
         (SELECT (mood, appetite, sleep, note, hygiene_shower, hygiene_grooming) FROM before)
      THEN 'care'

    WHEN (SELECT count(*) FROM (
            SELECT slot, happened, refused, amount FROM care_day_meals
             WHERE care_day_id = (SELECT id FROM this)
            EXCEPT ALL
            SELECT slot, happened, refused, amount FROM care_day_meals
             WHERE care_day_id = (SELECT id FROM before)) d) > 0
      OR (SELECT count(*) FROM (
            SELECT slot, happened, refused, amount FROM care_day_meals
             WHERE care_day_id = (SELECT id FROM before)
            EXCEPT ALL
            SELECT slot, happened, refused, amount FROM care_day_meals
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
