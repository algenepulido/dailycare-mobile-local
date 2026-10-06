-- A care manager puts somebody in the building, and the database is what decides they may.
--
-- identity-policies.sql carries a sentence that has been true until this file: "Membership
-- is granted and ended by an administrator, not through a request. No insert, update or
-- delete policy exists for the application on this table." The administrator it meant was
-- bootstrap, run from a terminal by whoever set the building up. Milestone five is the one
-- where a care manager does it from the app instead, so the sentence stops being true here
-- rather than quietly over several files.
--
-- facility_members decides who exists, so every policy below is aimed at as well as
-- written: a manager at one building trying the same thing at another is in the checks.
--
-- The shape is contact-acceptance.sql's, deliberately. A membership opens at 'invited' and
-- waits for the person to accept, the same way a family grant does, and it is the same
-- redeem that moves it. One mechanism, not two.


-- ════════════════════════════════════════════════════════════════════ who may invite

-- A care manager somewhere, which is as narrow as users can be asked: the table has no
-- facility column, and an account exists before it belongs to a building.
--
-- Emergency access is deliberately not here, and this is the one place it parts company
-- with app_is_care_manager(). An emergency grant is a short, named, audited way to read a
-- building in a crisis. Creating accounts during one is not the same act, and an
-- unexpired grant should not quietly become a way to add people.
CREATE OR REPLACE FUNCTION app_is_care_manager_somewhere() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = pg_catalog, public AS $$
  SELECT EXISTS (
    SELECT 1 FROM facility_members fm
    WHERE fm.user_id     = app_user_id()
      AND fm.role        = 'care_manager'
      AND fm.state       = 'active'
      AND fm.ended_at IS NULL
  )
$$;

COMMENT ON FUNCTION app_is_care_manager_somewhere() IS
  'A care manager at any building, for the one question that is not about a building: may
   this person create an account at all. Not app_is_care_manager(), which admits an
   emergency grant - reading a building in a crisis and adding people to it are different
   acts and only one of them is what that grant was for.';


-- The account of somebody being invited, and nothing else about anybody. What stops this
-- being more than that is the column grant below rather than this policy: email and
-- display_name are the whole of it, so password_hash is not reachable by the person doing
-- the inviting and deactivated_at is not reachable at all. The invitee sets their own
-- password through redeem_token, which is the only route to that column.
CREATE POLICY users_manager_invites ON users FOR INSERT
  WITH CHECK (app_is_care_manager_somewhere());

COMMENT ON POLICY users_manager_invites ON users IS
  'A care manager creates the account of somebody they are inviting. They do not set its
   password, and there is no column grant through which they could.';


-- ════════════════════════════════════════════════════════════════════ the membership

-- A membership is added to the manager's own building, in the state the enum has always
-- opened at, by somebody who is named in it.
--
-- state is not in the column grant below, so 'invited' arrives as the column default and
-- there is no request that can name anything else. The clause here says the same thing a
-- second time, where a reader of the policies will find it: the grant is what refuses, and
-- this is what explains.
--
-- invited_by = app_user_id() is the half that cannot be forged. schema-invariants.sql
-- already says this column answers who let somebody into the building; a value the
-- requester chose would answer nothing.
CREATE POLICY members_manager_invites ON facility_members FOR INSERT
  WITH CHECK (
    app_is_care_manager(facility_id)
    AND state      = 'invited'
    AND ended_at  IS NULL
    AND invited_by = app_user_id()
  );

COMMENT ON POLICY members_manager_invites ON facility_members IS
  'A care manager adds somebody to their own building, invited rather than active, and is
   recorded as the one who did it. Another building is app_is_care_manager() answering no.';


-- Ending a membership would leave the building with nobody who can run it.
--
-- The facility screen is the thing that removes bootstrap from the job, so a building that
-- can be left with no active care manager has a way in only through the terminal that
-- milestone five exists to retire. Twelve lines here against a support incident with no
-- in-app answer.
--
-- A function because the question is about facility_members and the policy is on
-- facility_members: a subquery recurses, and identity-policies.sql records PostgreSQL
-- refusing exactly that the first time this file's neighbour was written.
CREATE OR REPLACE FUNCTION app_is_last_care_manager(target_member uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = pg_catalog, public AS $$
  SELECT fm.role = 'care_manager'
     AND NOT EXISTS (
       SELECT 1 FROM facility_members other
       WHERE other.facility_id = fm.facility_id
         AND other.id         <> fm.id
         AND other.role        = 'care_manager'
         AND other.state       = 'active'
         AND other.ended_at   IS NULL)
    FROM facility_members fm
   WHERE fm.id = target_member
$$;

COMMENT ON FUNCTION app_is_last_care_manager(uuid) IS
  'Whether ending this membership would leave its facility with no active care manager.
   False for a caregiver, who is not what keeps a building administrable.';


-- A membership ends on a date. It is not deleted, and the rows the person filed are
-- untouched - ON DELETE RESTRICT on every reference to users is what makes that structural
-- rather than a habit.
--
-- USING reads the row as it stands and WITH CHECK reads what it would become, so between
-- them this is one defined transition: an open membership becomes a revoked one with an
-- end date. A policy cannot compare the two, which is why the transition is pinned at both
-- ends instead.
--
-- Pinning state = 'revoked' is the load-bearing half, and contact-acceptance.sql is where
-- the reason is written down: the application holds UPDATE on this column for this path,
-- so a policy that let a manager write any state would let a manager accept an invitation
-- on somebody else's behalf. Ending is a manager's. Accepting is not.
CREATE POLICY members_manager_ends ON facility_members FOR UPDATE
  USING (
    app_is_care_manager(facility_id)
    AND ended_at IS NULL
    AND NOT app_is_last_care_manager(id)
  )
  WITH CHECK (
    app_is_care_manager(facility_id)
    AND ended_at IS NOT NULL
    AND state     = 'revoked'
  );

COMMENT ON POLICY members_manager_ends ON facility_members IS
  'A caregiver leaves, or a second manager does. One transition: open becomes revoked with
   a date. Not the last manager at the building, which would leave it with no way back
   except the terminal this milestone exists to retire.';


-- Accepting is the person's own, and it is the only thing about their membership they may
-- do. The same shape as contacts_accept, for the same reason and against the same risk.
CREATE POLICY members_accept ON facility_members FOR UPDATE
  USING      (user_id = app_user_id() AND state = 'invited')
  WITH CHECK (user_id = app_user_id() AND state = 'active');

COMMENT ON POLICY members_accept ON facility_members IS
  'A person accepts the invitation that was sent to them, and nothing else. The invitation
   was the facility''s decision and is recorded as theirs; this is only the acceptance.';


-- ════════════════════════════════════════════════════════════════════ accepting it

-- The third version of this function, and the second to grow a line at the end of it.
-- contact-acceptance.sql is where the rest is explained; what is new is the last update.

CREATE OR REPLACE FUNCTION redeem_token(candidate_hash text, for_purpose text, new_hash text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, public AS $$
DECLARE owner uuid;
BEGIN
  UPDATE user_tokens SET consumed_at = now()
  WHERE token_hash  = candidate_hash
    AND purpose     = for_purpose
    AND consumed_at IS NULL
    AND expires_at  > now()
  RETURNING user_id INTO owner;

  IF owner IS NULL THEN
    RETURN NULL;   -- already used, expired, or for something else
  END IF;

  -- reject_unhashed_credential on users is what checks new_hash is an Argon2id digest.
  -- Not repeated here: one guard, on the column, that everything writing to it meets.
  UPDATE users
     SET password_hash = new_hash, updated_at = now()
   WHERE id = owner AND deactivated_at IS NULL;

  IF NOT FOUND THEN
    -- A good link on an account that has since been deactivated. Raising rolls the
    -- consume back with it, so the link is not silently burned on somebody who would then
    -- have neither a way in nor a way to ask for another.
    RAISE EXCEPTION 'that account is not active'
      USING HINT = 'The link is still unused. The account has to be reactivated first.';
  END IF;

  -- Every session on record ends. A password arriving from an invitation means the
  -- account is new; from a reset it means somebody believes it was compromised. Neither
  -- wants a session opened before it to keep working.
  --
  -- What this does not do, and it matters: an access token already in somebody's hand
  -- keeps working until it expires. The application verifies those against a signature
  -- and a clock and never asks this database, which is what keeps a read off every
  -- request - so ending a session here stops the refresh and not the fifteen minutes
  -- before it. Measured on the deployed instance rather than assumed: a token taken
  -- before a reset still answered 200 afterwards.
  --
  -- Closing that window means a lookup per request, which is a different system. The
  -- window is the design; writing it down is so that nobody reads the line above and
  -- believes a reset is instant.
  --
  -- Written here rather than through revoke_all_sessions, which refuses: that function
  -- checks the caller is the person whose sessions are ending, and during a redeem there
  -- is no session yet to be that person. The check is right for the case it guards - an
  -- application ending somebody else's access - and this is not that case. What stands in
  -- for it is the line above: the token was unused, unexpired, and issued for this user,
  -- or nothing here runs at all.
  UPDATE sessions SET revoked_at = now()
   WHERE user_id = owner AND revoked_at IS NULL AND expires_at > now();

  -- A family member's grant waits here until they accept it.
  --
  -- resident_contacts opens at 'invited', which is what the enum has always said it means
  -- and what nothing until now could produce: bootstrap writes a caregiver's membership
  -- straight to 'active', because for staff the only open question is whether they have a
  -- password. A family grant is a disclosure, and a facility that has sent an invitation
  -- and one that has a reader are different things for it to see.
  --
  -- app_is_contact() requires 'active', so until this line runs the grant allows nothing.
  -- granted_by and granted_at are untouched: they record the facility's decision, which
  -- happened when the row was written, not when the person got round to accepting it.
  -- Identify them before the update, because the update is theirs to make.
  --
  -- resident_contacts is forced, so this function - SECURITY DEFINER, running as the
  -- owner - answers to its policies like anybody else, and a redeem arrives with no
  -- session identity at all. The grant stayed 'invited' and nothing said so: an update
  -- a policy refuses changes no rows and raises nothing, so the password was written,
  -- the sessions were ended, this returned the user, and the one thing it was added to
  -- do quietly did not happen.
  --
  -- The identity is not a guess. Four lines above, a token that was unused, unexpired
  -- and issued to this user was consumed. That is the proof; this is the conclusion.
  -- Transaction-local, so it ends with the redeem.
  PERFORM set_config('app.user_id', owner::text, true);

  UPDATE resident_contacts
     SET state = 'active', updated_at = now()
   WHERE user_id = owner AND state = 'invited';

  -- A membership waits here too, and for the same reason the grant above does.
  --
  -- bootstrap wrote a caregiver's membership straight to 'active', because when a terminal
  -- put somebody in a building the only open question was whether they had a password.
  -- member-invitation.sql makes a care manager the one who adds them, and the two questions
  -- come apart again: a facility that has sent an invitation and a facility that has
  -- somebody working in it are different things for it to see.
  --
  -- Every predicate the policies are built from requires 'active' - app_my_facilities,
  -- app_is_care_manager, app_is_care_manager_somewhere - so until this line runs an invited
  -- membership allows nothing at all.
  --
  -- invited_by and started_at are untouched. They record the facility's decision, which
  -- happened when the row was written and not when the person got round to accepting it.
  --
  -- The identity set above is what makes this reachable at all, and facility_members is
  -- ENABLE rather than FORCE, so this function running as the owner is exempt from its
  -- policies here. That exemption is what hid the contact bug for a release. It is why the
  -- check for this line runs as dailycare_app and not as the owner.
  UPDATE facility_members
     SET state = 'active', updated_at = now()
   WHERE user_id = owner AND state = 'invited';

  RETURN owner;
END; $$;


-- ════════════════════════════════════════════════════════════════════ and the grants

-- A migration that adds a privilege adds a row, which is what apply_app_privileges() is
-- for and what keeps grant_drift empty in both directions.
--
-- Every one of these names its columns. A table-level grant is every column including the
-- ones added later, and grants.sql already records what that cost on users: the only way
-- to leave a column out is to never include it.

INSERT INTO app_privileges (grantee, table_name, privilege, columns, note) VALUES
('dailycare_app','users','INSERT', ARRAY['id','email','display_name'],
 'The account of somebody being invited. Not password_hash, which has one route and it is
  redeem_token. Not email_verified_at or second_factor_enrolled_at, which are things a
  person does and not things a manager asserts about them. Not deactivated_at: an account
  is not created already closed.

  id is here because of something the read policies make true: a manager who has just
  created an account cannot see it. users has three read policies - myself, a colleague at
  my building, a family member I granted access to - and somebody with no membership yet is
  none of them, so the row is invisible to the one person who needs its id next. The
  application names the account instead of asking for it back. Measured rather than
  reasoned about: without this the membership insert selected the new user, matched no rows
  and wrote nothing, which is the quiet kind of wrong.'),

('dailycare_app','facility_members','INSERT',
 ARRAY['facility_id','user_id','role','invited_by'],
 'A manager adds somebody to a building. state is not here, so the column default is the
  only value an insert can carry and it is ''invited''. The policy says so as well, and the
  two are not interchangeable even though both answer 42501: widening this array changed
  nothing any check could see until one was written that satisfies the policy and names the
  column anyway. ended_at is not here either - a membership is not created already over -
  and neither is started_at, which would let one be backdated.'),

('dailycare_app','facility_members','UPDATE', ARRAY['state','ended_at','updated_at'],
 'Two paths share these three columns and the policies keep them apart: a manager ends a
  membership, which is state revoked with a date, and the person accepts their own, which
  is invited to active. Not role - somebody does not become a care manager by an update,
  for the same reason a resident does not move buildings by one. Not facility_id, not
  user_id, and not invited_by, which is the answer to who let them in.

  The ending policy is tight enough that it refuses almost any other update by itself, so
  this array reads as decoration until something asks it on its own. A valid ending that
  carries a role change with it is what asks, and access-invariants.sql does.');

SELECT apply_app_privileges();
