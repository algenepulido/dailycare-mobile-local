-- DailyCare access control
--
-- The role model from Milestone 2, written as row-level security rather than as a table
-- in a document. The difference matters: a matrix describes what the application intends,
-- and a policy is what the database will actually permit. A reviewer can read the first;
-- only the second survives a mistake in a handler.
--
-- Applied after schema.sql. The application connects as a non-owner role and sets one
-- session variable per request:
--
--   SET LOCAL app.user_id = '<the authenticated user>';
--
-- Every policy below resolves from that. There is no "admin" bypass in the application
-- path — a request with no app.user_id set sees nothing at all, which is the correct
-- behaviour for a bug that forgets to set it.
--
-- Three roles:
--
--   caregiver      reads and writes the care record of residents currently assigned to
--                  them, inside their own facility. Not the whole building.
--   care_manager   reads and writes every resident in their own facility.
--   family member  reads the care record of residents they hold active access to.
--                  Never writes. They receive care; they do not record it.


-- ════════════════════════════════════════════════════════════════════ who is asking

CREATE OR REPLACE FUNCTION app_user_id() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('app.user_id', true), '')::uuid
$$;

COMMENT ON FUNCTION app_user_id() IS
  'Null when unset, and null compares false everywhere below — so a request that forgets
   to identify itself reads nothing rather than everything.';


-- The membership lookups run as the definer so that policies on one table do not trigger
-- policies on another and recurse. They are read-only and take a single resident.

CREATE OR REPLACE FUNCTION app_is_care_manager(target_facility uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT EXISTS (
    SELECT 1 FROM facility_members fm
    WHERE fm.user_id     = app_user_id()
      AND fm.facility_id = target_facility
      AND fm.role        = 'care_manager'
      AND fm.state       = 'active'
      AND fm.ended_at IS NULL
  )
$$;

CREATE OR REPLACE FUNCTION app_is_assigned(target_resident uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER AS $$
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
  )
$$;

CREATE OR REPLACE FUNCTION app_is_contact(target_resident uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT EXISTS (
    SELECT 1 FROM resident_contacts rc
    WHERE rc.user_id     = app_user_id()
      AND rc.resident_id = target_resident
      AND rc.state       = 'active'
  )
$$;

-- Reading a resident's record. Staff by assignment or management, family by grant.
CREATE OR REPLACE FUNCTION app_may_read_resident(target_resident uuid, target_facility uuid)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT app_is_care_manager(target_facility)
      OR app_is_assigned(target_resident)
      OR app_is_contact(target_resident)
$$;

-- Writing it. The same, minus family — which is the whole point of separating them.
CREATE OR REPLACE FUNCTION app_may_write_resident(target_resident uuid, target_facility uuid)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT app_is_care_manager(target_facility)
      OR app_is_assigned(target_resident)
$$;


-- ════════════════════════════════════════════════════════════════════ policies
--
-- FORCE, not just ENABLE. Without it the table owner is exempt, and the owner is exactly
-- who the application would be connecting as on the day somebody takes a shortcut.

ALTER TABLE residents          ENABLE ROW LEVEL SECURITY;
ALTER TABLE residents          FORCE  ROW LEVEL SECURITY;
ALTER TABLE care_days          ENABLE ROW LEVEL SECURITY;
ALTER TABLE care_days          FORCE  ROW LEVEL SECURITY;
ALTER TABLE care_day_meals     ENABLE ROW LEVEL SECURITY;
ALTER TABLE care_day_meals     FORCE  ROW LEVEL SECURITY;
ALTER TABLE care_day_concerns  ENABLE ROW LEVEL SECURITY;
ALTER TABLE care_day_concerns  FORCE  ROW LEVEL SECURITY;
ALTER TABLE medication_events  ENABLE ROW LEVEL SECURITY;
ALTER TABLE medication_events  FORCE  ROW LEVEL SECURITY;
ALTER TABLE media_objects      ENABLE ROW LEVEL SECURITY;
ALTER TABLE media_objects      FORCE  ROW LEVEL SECURITY;
ALTER TABLE resident_contacts  ENABLE ROW LEVEL SECURITY;
ALTER TABLE resident_contacts  FORCE  ROW LEVEL SECURITY;


-- ── residents ──────────────────────────────────────────────────────────────────

CREATE POLICY residents_read ON residents FOR SELECT
  USING (app_may_read_resident(id, facility_id));

-- Only a care manager creates or edits a resident. A caregiver files days about them;
-- they do not admit them or change their baseline.
-- Deliberately not FOR ALL. ALL includes DELETE, which is how a policy meant to say
-- "a manager may admit and correct a resident" quietly also says "and may destroy one".
-- Found by the access matrix, which compares what the catalogue permits against what the
-- model claims, and reported a DELETE policy on a table nothing is supposed to be deleted
-- from. Every write policy below is spelled out for the same reason.
CREATE POLICY residents_insert ON residents FOR INSERT
  WITH CHECK (app_is_care_manager(facility_id));

CREATE POLICY residents_update ON residents FOR UPDATE
  USING      (app_is_care_manager(facility_id))
  WITH CHECK (app_is_care_manager(facility_id));


-- ── the care record ────────────────────────────────────────────────────────────

CREATE POLICY care_days_read ON care_days FOR SELECT
  USING (app_may_read_resident(resident_id, facility_id));

CREATE POLICY care_days_write ON care_days FOR INSERT
  WITH CHECK (app_may_write_resident(resident_id, facility_id));

-- Update exists only to stamp superseded_at. The correction itself is a new row, so
-- there is no policy that lets anyone rewrite what a day said.
CREATE POLICY care_days_supersede ON care_days FOR UPDATE
  USING      (app_may_write_resident(resident_id, facility_id))
  WITH CHECK (app_may_write_resident(resident_id, facility_id));

-- No DELETE policy anywhere in this file. A care record is retired by policy, by the
-- retention job running as its own role — never by a request.


CREATE POLICY care_day_meals_read ON care_day_meals FOR SELECT
  USING (EXISTS (SELECT 1 FROM care_days cd WHERE cd.id = care_day_id
                   AND app_may_read_resident(cd.resident_id, cd.facility_id)));

CREATE POLICY care_day_meals_insert ON care_day_meals FOR INSERT
  WITH CHECK (EXISTS (SELECT 1 FROM care_days cd WHERE cd.id = care_day_id
                        AND app_may_write_resident(cd.resident_id, cd.facility_id)));

CREATE POLICY care_day_meals_update ON care_day_meals FOR UPDATE
  USING      (EXISTS (SELECT 1 FROM care_days cd WHERE cd.id = care_day_id
                        AND app_may_write_resident(cd.resident_id, cd.facility_id)))
  WITH CHECK (EXISTS (SELECT 1 FROM care_days cd WHERE cd.id = care_day_id
                        AND app_may_write_resident(cd.resident_id, cd.facility_id)));

CREATE POLICY care_day_concerns_read ON care_day_concerns FOR SELECT
  USING (EXISTS (SELECT 1 FROM care_days cd WHERE cd.id = care_day_id
                   AND app_may_read_resident(cd.resident_id, cd.facility_id)));

CREATE POLICY care_day_concerns_insert ON care_day_concerns FOR INSERT
  WITH CHECK (EXISTS (SELECT 1 FROM care_days cd WHERE cd.id = care_day_id
                        AND app_may_write_resident(cd.resident_id, cd.facility_id)));

CREATE POLICY care_day_concerns_update ON care_day_concerns FOR UPDATE
  USING      (EXISTS (SELECT 1 FROM care_days cd WHERE cd.id = care_day_id
                        AND app_may_write_resident(cd.resident_id, cd.facility_id)))
  WITH CHECK (EXISTS (SELECT 1 FROM care_days cd WHERE cd.id = care_day_id
                        AND app_may_write_resident(cd.resident_id, cd.facility_id)));


-- ── medication ─────────────────────────────────────────────────────────────────

CREATE POLICY medication_read ON medication_events FOR SELECT
  USING (app_may_read_resident(resident_id, facility_id));

-- A caregiver may record what they gave. Nobody may write a row claiming to have come
-- from a clinical system — those arrive through the integration's own role, not through
-- a request, so a compromised session cannot forge an entry attributed to a MedTech.
CREATE POLICY medication_write ON medication_events FOR INSERT
  WITH CHECK (app_may_write_resident(resident_id, facility_id)
              AND source = 'caregiver');


-- ── media ──────────────────────────────────────────────────────────────────────

CREATE POLICY media_read ON media_objects FOR SELECT
  USING (deleted_at IS NULL AND app_may_read_resident(resident_id, facility_id));

CREATE POLICY media_write ON media_objects FOR INSERT
  WITH CHECK (app_may_write_resident(resident_id, facility_id));

COMMENT ON POLICY media_read ON media_objects IS
  'This is the row that gates a signed URL. The URL is minted after this policy has
   admitted the caller, and never before — so possession of a link is not permission,
   and an expired grant cannot be replayed by keeping an old link.';


-- ── family access rows ─────────────────────────────────────────────────────────

-- A family member may see their own grants, so the app can show them which residents
-- they are linked to. They cannot see anybody else's.
CREATE POLICY contacts_read ON resident_contacts FOR SELECT
  USING (user_id = app_user_id() OR app_is_care_manager(facility_id));

-- Only a care manager grants or withdraws access. A caregiver files care; they do not
-- decide who in a family may read it.
CREATE POLICY contacts_insert ON resident_contacts FOR INSERT
  WITH CHECK (app_is_care_manager(facility_id));

-- Access is withdrawn by revoking the row, never by removing it: revoked_by and revoked_at
-- are answers a reviewer asks for, and neither can be reconstructed from a row that is
-- gone. Which is also why there is no DELETE policy here.
CREATE POLICY contacts_update ON resident_contacts FOR UPDATE
  USING      (app_is_care_manager(facility_id))
  WITH CHECK (app_is_care_manager(facility_id));
