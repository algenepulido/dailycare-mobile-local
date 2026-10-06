-- Access that was withdrawn, given back - and the two transitions either side of it named.
--
-- resident_contacts carries UNIQUE (resident_id, user_id), so a withdrawn grant cannot be
-- made again: the row is still there, revoked, which is the design. Restoring it is an
-- update of that row and nothing did one.
--
-- Writing it meant looking at what was already allowed, and contacts_update was wider than
-- the comment above it described. It admitted a care manager and said nothing about which
-- transition, so a manager could move a grant from 'invited' straight to 'active' - turning
-- a disclosure on for somebody who had never accepted it. Nothing did that. It was still
-- the shape contact-acceptance.sql warned about from the other side, where it explains why
-- the accept policy had to be narrow: "dailycare_app holds UPDATE on this table's state
-- column for the revocation path, so a policy admitting the transition alone would hand the
-- application the power to turn a disclosure on."
--
-- So the three transitions are three policies and none of them can do another's work.
-- Withdrawing is a manager's. Restoring is a manager's, and lands on 'invited' rather than
-- 'active'. Accepting is the person's, and contact-acceptance.sql already wrote it.
--
-- Restoring to 'invited' is the decision in this file and it costs a step: somebody whose
-- access was withdrawn by mistake has to accept again. What it buys is that 'active' means
-- one thing everywhere - this person accepted this grant - with no case where a facility
-- put somebody into it. A facility re-offering a disclosure it took back is a new decision,
-- and contact-acceptance.sql's own words are why: a facility that has sent an invitation
-- and one that has a reader are different things for it to see.


DROP POLICY IF EXISTS contacts_update ON resident_contacts;

-- Access is withdrawn by revoking the row, never by removing it. revoked_by and revoked_at
-- are answers a reviewer asks for and neither can be reconstructed from a row that is gone,
-- which is also why there is no delete policy here.
--
-- Pinned at both ends, the way the membership policies are: a grant that is not already
-- revoked becomes one that is, dated, carrying the name of the manager who did it. A policy
-- cannot compare the row before with the row after, so the transition is held at each end
-- instead.
CREATE POLICY contacts_withdraw ON resident_contacts FOR UPDATE
  USING      (app_is_care_manager(facility_id) AND state <> 'revoked')
  WITH CHECK (app_is_care_manager(facility_id) AND state = 'revoked'
              AND revoked_by = app_user_id() AND revoked_at IS NOT NULL);

COMMENT ON POLICY contacts_withdraw ON resident_contacts IS
  'A care manager takes back access, and the row records that they did. The only thing this
   admits is becoming revoked: it cannot turn a grant on, which is the half the policy it
   replaced was missing.';


-- And back again, to where a grant starts rather than to where it ended.
--
-- revoked_by and revoked_at are left where they are. They record a withdrawal that happened,
-- and a restored grant that has forgotten being withdrawn is a row that disagrees with the
-- trail. A reader wanting "offered again after being taken back" has it already: state
-- 'invited' with revoked_at set is that, and needs no column of its own.
CREATE POLICY contacts_restore ON resident_contacts FOR UPDATE
  USING      (app_is_care_manager(facility_id) AND state = 'revoked')
  WITH CHECK (app_is_care_manager(facility_id) AND state = 'invited');

COMMENT ON POLICY contacts_restore ON resident_contacts IS
  'A care manager offers access again. It lands where a grant starts, waiting for the person
   to accept it, so that ''active'' never means anything but that they did.';


-- Two columns the application held and no path needs.
--
-- granted_by and granted_at record the decision that made the grant, which happens at the
-- insert. An update that could rewrite them is an update that could say somebody else made
-- it, and that is the same hole decisions-have-authors.sql closed on the way in.
--
-- apply_app_privileges() only grants, so narrowing one is a REVOKE written here. The row is
-- corrected as well, or grant_drift reports the difference as somebody having granted a
-- privilege by hand - which is exactly what the drift view is for and exactly what this is
-- not.
REVOKE UPDATE (granted_by, granted_at) ON resident_contacts FROM dailycare_app;

UPDATE app_privileges
   SET columns = ARRAY['state','revoked_by','revoked_at','updated_at'],
       note    = 'Access is withdrawn by revoking the row and offered again by returning it
  to invited. Not the resident it is for, not the person it is for, and no longer granted_by
  or granted_at: those record the decision that made the grant, which happened at the insert
  and is not an update''s to rewrite.'
 WHERE grantee = 'dailycare_app' AND table_name = 'resident_contacts' AND privilege = 'UPDATE';


-- ════════════════════════════════════════════════════════════════════ and who offered it

-- Somebody with a grant waiting for them cannot read the name of the building that offered
-- it. facilities_mine is built on app_my_contact_facilities(), which requires 'active' - so
-- the one person a pending grant is for is the one person who cannot see whose it is.
--
-- Found while writing the screen that shows them: the query returned nothing, for exactly
-- the people it was for.
--
-- A second policy rather than a wider first one. Policies are OR'd, so this adds the case
-- without touching the sentence identity-policies.sql wrote about family members seeing one
-- building and no other - and it adds only the pending case. A withdrawn grant drops out of
-- it, which is the point: somebody whose access was taken back should stop seeing the name
-- along with everything else.
CREATE POLICY facilities_offered ON facilities FOR SELECT
  USING (EXISTS (SELECT 1 FROM resident_contacts rc
                  WHERE rc.facility_id = facilities.id
                    AND rc.user_id     = app_user_id()
                    AND rc.state       = 'invited'));

COMMENT ON POLICY facilities_offered ON facilities IS
  'The name of a building that has offered somebody access and is waiting for an answer. Not
   the residents in it and not anything they have filed - app_is_contact still wants
   ''active'' for all of that. Just enough to say who is asking.';
