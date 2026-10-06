-- Three columns answer "who decided this", and only one of them could not be made up.
--
-- facility_members.invited_by is pinned to the requester by member-invitation.sql, because
-- a value the requester chose would answer nothing. The other two were not, and they are
-- the more consequential half: a membership grants nothing on its own, while an assignment
-- is what lets one named person read one named resident's record, and a family grant is a
-- disclosure to somebody outside the building.
--
-- Both were kept honest in Go instead. bootstrap sets granted_by to the manager making the
-- grant and there is a commit named for it, which is the right behaviour in the wrong place:
-- it is a property of whichever handler last touched the table, and milestone five is adding
-- handlers. So the rule moves to where it cannot be worked around.
--
-- And one grant that was never there. assignments_manager_writes has existed since the
-- policies were written and nothing could exercise it: the application holds SELECT and
-- UPDATE (ended_at) on assignments and no INSERT at all, so a care manager putting a
-- caregiver in front of a resident was a terminal job like everything else milestone five
-- is moving. A policy with no grant behind it reads as a control and is not one.


-- ════════════════════════════════════════════════════════════════════ assignments

DROP POLICY IF EXISTS assignments_manager_writes ON assignments;

-- Same reach as before and two clauses that were missing. assigned_by is the requester or
-- the row is refused; an assignment is not created already over.
--
-- The column stays nullable and this does not change that. Seed rows have no author and an
-- assignment arriving from a facility's own system will not have a DailyCare user behind it
-- - both of those are written by the owner, which is exempt here, and
-- assignments_without_an_author is what keeps the gap visible.
CREATE POLICY assignments_manager_writes ON assignments FOR INSERT
  WITH CHECK (
    app_is_care_manager(facility_id)
    AND assigned_by = app_user_id()
    AND ended_at IS NULL
  );

-- ended_at IS NULL cannot be reached from the application and is here for the day the grant
-- below changes. Both halves were measured: removing this clause turned nothing red, because
-- the column is outside the insert grant and the request is refused before a row is judged.
-- Kept rather than dropped, and said rather than left to be rediscovered.
COMMENT ON POLICY assignments_manager_writes ON assignments IS
  'A care manager puts one caregiver in front of one resident, in their own building, and is
   recorded as the one who did it. Who gave somebody access to her is a question a reviewer
   asks, and an answer the requester supplied would not be one.';

INSERT INTO app_privileges (grantee, table_name, privilege, columns, note) VALUES
('dailycare_app','assignments','INSERT',
 ARRAY['facility_id','resident_id','facility_member_id','assigned_by'],
 'The grant assignments_manager_writes has been waiting for. Not started_at, which would let
  an assignment be backdated, and not ended_at, which would let one be created already over -
  the same two the membership insert leaves out, for the same reasons.');

SELECT apply_app_privileges();


-- ════════════════════════════════════════════════════════════════════ family grants

DROP POLICY IF EXISTS contacts_insert ON resident_contacts;

CREATE POLICY contacts_insert ON resident_contacts FOR INSERT
  WITH CHECK (
    app_is_care_manager(facility_id)
    AND granted_by = app_user_id()
  );

COMMENT ON POLICY contacts_insert ON resident_contacts IS
  'Only a care manager grants access, and the grant carries their name because they made it.
   A caregiver files care; they do not decide who in a family may read it. State is not
   pinned here: family-access.sql opens a grant at ''invited'' by column default and
   contact-acceptance.sql is what moves it, and neither is this policy''s business.';
