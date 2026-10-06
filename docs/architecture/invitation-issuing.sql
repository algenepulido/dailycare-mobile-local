-- A manager hands somebody a way in, and the application never gets a grant to do it with.
--
-- user_tokens is not in any INSERT grant and is not going to be. An invitation is a bearer
-- credential: whoever may write that table may mint a way into any account in the cluster,
-- and "the handler only does it for their own building" is a property of a handler rather
-- than of the system. So the route is a function, the function is the one thing granted,
-- and what it will do is the whole of what the application can do.
--
-- Until this, bootstrap was that route - a terminal, printing a link once. member-invitation
-- .sql made a care manager the one who adds somebody to a building; this is the half that
-- lets the person they added actually arrive.


-- Whether a person already has a way in.
--
-- bootstrap carries this rule in Go: an invitation only for somebody who has none yet. A
-- second grant for an account that already exists needs no new credential, because
-- redeem_token activates every invited grant and every invited membership the account
-- holds, so signing in is enough. Written here instead so the rule belongs to the database
-- and the next caller cannot get it wrong by not knowing it.
CREATE OR REPLACE FUNCTION app_has_a_way_in(target_user uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = pg_catalog, public AS $$
  SELECT EXISTS (SELECT 1 FROM users u
                  WHERE u.id = target_user
                    AND u.password_hash IS NOT NULL
                    AND u.deactivated_at IS NULL)
      OR EXISTS (SELECT 1 FROM user_tokens t
                  WHERE t.user_id    = target_user
                    AND t.purpose    = 'invitation'
                    AND t.consumed_at IS NULL
                    AND t.expires_at  > now())
$$;

COMMENT ON FUNCTION app_has_a_way_in(uuid) IS
  'A password, or an invitation still unused and unexpired. Either is a way in, and issuing
   a second one would be a second bearer credential for the same person because a facility
   added them to something.';


-- The whole of what the application may do to user_tokens.
--
-- Handed out because it cannot be used for anything else: one invitation, for one account,
-- and only one the caller administers - somebody they have put in their own building, or a
-- family member they have granted access to at it. Both are decisions this caller already
-- made through a policy, so this adds no reach; it gives the person those decisions were
-- about a way to arrive.
--
-- Returns whether a link was issued. False is not a failure: it is somebody who already has
-- a password or an outstanding invitation, and the screen says so rather than minting a
-- second credential. Only a refusal raises.
CREATE OR REPLACE FUNCTION issue_invitation(target_user uuid, digest text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, public AS $$
DECLARE mine boolean;
BEGIN
  SELECT EXISTS (SELECT 1 FROM facility_members fm
                  WHERE fm.user_id = target_user
                    AND app_is_care_manager(fm.facility_id))
      OR EXISTS (SELECT 1 FROM resident_contacts rc
                  WHERE rc.user_id = target_user
                    AND app_is_care_manager(rc.facility_id))
    INTO mine;

  -- 42501, so it arrives at the application as the same kind of answer every other refusal
  -- in this model gives and is mapped once rather than per call site.
  IF NOT mine THEN
    RAISE EXCEPTION 'that is not somebody you administer'
      USING ERRCODE = '42501',
            HINT = 'An invitation goes to somebody you have put in your building or granted access to.';
  END IF;

  IF app_has_a_way_in(target_user) THEN
    RETURN false;
  END IF;

  -- Seven days, the same as bootstrap's. is_sha256_hex on the column is what checks the
  -- digest, not repeated here: one guard, on the column, that everything writing to it meets.
  INSERT INTO user_tokens (user_id, purpose, token_hash, expires_at)
  VALUES (target_user, 'invitation', digest, now() + interval '7 days');
  RETURN true;
END; $$;

COMMENT ON FUNCTION issue_invitation(uuid, text) IS
  'One invitation, for one account the caller administers, and only when that account has no
   way in yet. The application has no grant on user_tokens and this is the only route to it.';

REVOKE ALL ON FUNCTION issue_invitation(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION issue_invitation(uuid, text) TO dailycare_app;
