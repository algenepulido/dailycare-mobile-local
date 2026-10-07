-- One open assignment per caregiver per resident, which nothing said.
--
-- An assignment is a current fact with a date for when it stops, so the same caregiver being
-- assigned to the same resident twice at once says nothing the first row did not. The model
-- had no constraint against it and the facility screen is what made that visible: a resident
-- on staging read "Maria Santos, Maria Santos, Maria Santos, Maria Santos, Maria Santos,
-- Tomas Vega", which is one seeded assignment repeated every time the seed ran.
--
-- The seed thought it was idempotent. It ends its insert with ON CONFLICT DO NOTHING, and
-- with nothing to conflict on that clause is a comment: PostgreSQL has no arbiter to match,
-- so every run inserted another row and the guard never fired. The clause was right about
-- the intent and wrong about there being anything to enforce it.
--
-- Same shape as care_days_current_per_day: a partial unique index, so the history of who
-- looked after whom stays whole and only the open ones are held to being distinct. Ending
-- an assignment and making it again is still ordinary, which is the thing a facility does
-- when somebody changes shift.


-- The duplicates that already exist, closed before the index that forbids them.
--
-- Ended at their own started_at rather than at now(). A duplicate covered no time that the
-- row it duplicates did not already cover, and stamping today would put a date on the record
-- claiming somebody was taken off a resident this afternoon. The oldest open row per pair is
-- the one that stands - it is the one whose started_at the others were copying.
WITH ranked AS (
  SELECT id,
         row_number() OVER (PARTITION BY resident_id, facility_member_id
                            ORDER BY started_at, id) AS n
    FROM assignments
   WHERE ended_at IS NULL
)
UPDATE assignments a
   SET ended_at = a.started_at
  FROM ranked r
 WHERE a.id = r.id AND r.n > 1;

CREATE UNIQUE INDEX assignments_one_open_per_pair
  ON assignments (resident_id, facility_member_id)
  WHERE ended_at IS NULL;

COMMENT ON INDEX assignments_one_open_per_pair IS
  'A caregiver is either looking after this resident or not. Two open rows saying they are
   is one row and a copy of it, and the screen that lists who is assigned reads them both.';
