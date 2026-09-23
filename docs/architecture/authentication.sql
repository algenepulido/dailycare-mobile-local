-- Authentication
--
-- Applied after schema.sql.
--
-- Authorisation is in access-policies.sql and is enforced by the database. Authentication
-- is the step before it: deciding whose uuid goes into app.user_id. That decision is made
-- by the API, which makes it the weaker half by construction, so what can be moved into
-- the database has been.
--
-- Four things are here rather than in a handler:
--
--   A credential column refuses anything but a digest, so "we hash passwords" is a fact
--   about the table rather than about whichever handler last wrote to it. That is in
--   schema.sql, next to the columns it constrains.
--
--   A session is valid or it is not, and the answer is one function rather than a
--   condition repeated at every call site with one place that forgot the revocation check.
--
--   A single-use token is consumed atomically. An invitation link forwarded to two people,
--   or clicked twice on a flaky connection, admits exactly one of them - and that is a
--   property of the UPDATE rather than of the order requests happened to arrive in.
--
--   Signing out of one device does not sign out the others, and signing out everywhere
--   does. Both are rows, so a reviewer can be shown the difference.
--
-- What remains in the API: verifying the access token's signature, checking its expiry,
-- and setting app.user_id. The access token is short-lived and is not stored anywhere -
-- only the refresh token has a row, and only as a digest.


-- ════════════════════════════════════════════════════════════════════ signing in
--
-- The step before a session exists, and the one the access model cannot help with: every
-- read policy on users is predicated on app_user_id(), and at sign-in there is no such
-- thing yet. Without something here the application sees zero rows for any email and
-- nobody can ever sign in - which is what a real database said when it was asked.
--
-- So one definer function, and it is deliberately narrow.
--
-- It refuses to run once anybody is identified. An authenticated request has no business
-- asking for a credential, so the one path to a password digest is open only in the
-- moment before there is a session, which is the only moment it is needed. Without that
-- line this function is a hash-extraction tool for whoever gets a session first.
--
-- It says nothing different about an unknown address than about a known one with a wrong
-- password: the caller gets a row or it does not, and the API answers the same either way.
-- Deactivated accounts return nothing, so a termination closes the door rather than
-- leaving it to a handler to check afterwards.

CREATE OR REPLACE FUNCTION credential_for_sign_in(candidate_email citext)
RETURNS TABLE (user_id uuid, password_hash text)
LANGUAGE plpgsql STABLE SECURITY DEFINER
  SET search_path = pg_catalog, public AS $$
BEGIN
  IF nullif(current_setting('app.user_id', true), '') IS NOT NULL THEN
    RAISE EXCEPTION 'credential_for_sign_in is for the step before a session'
      USING ERRCODE = 'insufficient_privilege',
            HINT = 'An identified request does not need a password digest.';
  END IF;

  RETURN QUERY
    SELECT u.id, u.password_hash
    FROM users u
    WHERE u.email = candidate_email
      AND u.deactivated_at IS NULL
      AND u.password_hash IS NOT NULL;   -- an invitation that has not been accepted
END; $$;

COMMENT ON FUNCTION credential_for_sign_in(citext) IS
  'The only route to a password digest, and only before anybody is identified. Verifying
   it is the API''s job - argon2id is not something PostgreSQL can do - and that is the
   whole of what the API decides about authentication.';


-- ════════════════════════════════════════════════════════════════════ sessions

-- Definer, and it has to be. Every policy on sessions is predicated on app_user_id(),
-- and this is what runs before there is one: a request arrives with a refresh token and
-- this is the question that turns it into an identity. Running as the caller it saw no
-- rows and answered false for a session created a moment earlier, which reads as an
-- expired token and sends a caregiver back to the sign-in screen mid-shift.
--
-- Knowing the digest is the authorisation. It returns a boolean and nothing about who.
CREATE OR REPLACE FUNCTION session_is_valid(candidate_hash text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = pg_catalog, public AS $$
  SELECT EXISTS (
    SELECT 1 FROM sessions s
    JOIN users u ON u.id = s.user_id
    WHERE s.refresh_hash = candidate_hash
      AND s.revoked_at IS NULL
      AND s.expires_at > now()
      -- Idle as well as absolute. A session nobody has used since the shift before is not
      -- a session somebody is still in.
      AND (s.idle_expires_at IS NULL OR s.idle_expires_at > now())
      -- The person, not only the session. Without this, deactivating an account left the
      -- phone in somebody's pocket working until the refresh token expired - thirty days
      -- after a termination the procedure believed it had completed.
      AND u.deactivated_at IS NULL
  )
$$;

COMMENT ON FUNCTION session_is_valid(text) IS
  'One place, so that a call site cannot check expiry and forget revocation. Takes the
   digest, never the token: the token exists in the client and in one HTTP request, and
   nowhere else.';


-- Whose session this is. Definer for the same reason session_is_valid is: it answers a
-- question asked before there is an identity, which is the question that produces one.
--
-- It returns nothing for a session that is not currently usable, so a revoked or expired
-- token cannot be turned back into a name. Knowing the digest is the authorisation, and
-- what comes back is a uuid - not an address, not a display name.

CREATE OR REPLACE FUNCTION session_owner(candidate_hash text)
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = pg_catalog, public AS $$
  SELECT s.user_id FROM sessions s
  JOIN users u ON u.id = s.user_id
  WHERE s.refresh_hash = candidate_hash
    AND s.revoked_at IS NULL
    AND s.expires_at > now()
    AND (s.idle_expires_at IS NULL OR s.idle_expires_at > now())
    AND u.deactivated_at IS NULL
$$;

COMMENT ON FUNCTION session_owner(text) IS
  'The other half of session_is_valid: the same conditions, answering who rather than
   whether. Without it the API can rotate a session and then not know whose it was, because
   every policy on sessions needs the identity this is being asked for.';


-- Handing out the first session. New, because there was nowhere for one to come from:
-- the application holds no INSERT on sessions, deliberately - with it, a compromised
-- handler could mint a session for any user id it liked - so the row has to be written by
-- something that checks first.
--
-- The check is the same one credential_for_sign_in makes, and for the same reason: this is
-- only reachable in the moment before anybody is identified. An authenticated request
-- asking to be issued a session for somebody else is the shape of the attack, and it is
-- refused rather than audited.
--
-- It does not verify the password. That happens in the API, because argon2id is not
-- something PostgreSQL can do, and it is the whole of what the API decides here.

CREATE OR REPLACE FUNCTION start_session(
  for_user     uuid,
  new_hash     text,
  device       text DEFAULT NULL,
  valid_for    interval DEFAULT interval '30 days',
  idle_for     interval DEFAULT interval '12 hours'
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, public AS $$
DECLARE new_id uuid;
BEGIN
  IF nullif(current_setting('app.user_id', true), '') IS NOT NULL THEN
    RAISE EXCEPTION 'start_session is for the step before a session'
      USING ERRCODE = 'insufficient_privilege',
            HINT = 'An identified request asking to be issued a session is not signing in.';
  END IF;

  -- A deactivated account does not get a new session however convincing the password was.
  -- end_sessions_on_deactivation closes the ones that exist; this closes the door behind
  -- them.
  IF NOT EXISTS (SELECT 1 FROM users WHERE id = for_user AND deactivated_at IS NULL) THEN
    RAISE EXCEPTION 'no such user' USING ERRCODE = 'insufficient_privilege';
  END IF;

  INSERT INTO sessions (user_id, refresh_hash, device_label, expires_at, idle_expires_at)
  VALUES (for_user, new_hash, device, now() + valid_for, now() + idle_for)
  RETURNING id INTO new_id;
  RETURN new_id;
END; $$;

COMMENT ON FUNCTION start_session(uuid, text, text, interval, interval) IS
  'The only way a session comes into being. Definer, because the application holds no
   INSERT on sessions and should not: the row it would write is an assertion about who
   somebody is.';


-- Refresh rotation. The old session is revoked in the same statement that issues the new
-- one, so a stolen refresh token stops working the moment the real client uses theirs.
CREATE OR REPLACE FUNCTION rotate_session(
  old_hash    text,
  new_hash    text,
  valid_for   interval DEFAULT interval '30 days'
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, public AS $$
DECLARE
  owner   uuid;
  label   text;
  new_id  uuid;
BEGIN
  UPDATE sessions SET revoked_at = now()
  WHERE refresh_hash = old_hash AND revoked_at IS NULL AND expires_at > now()
    AND user_id IN (SELECT id FROM users WHERE deactivated_at IS NULL)
  RETURNING user_id, device_label INTO owner, label;

  IF owner IS NULL THEN
    RETURN NULL;   -- unknown, revoked or expired. The caller signs in again.
  END IF;

  INSERT INTO sessions (user_id, refresh_hash, device_label, expires_at)
  VALUES (owner, new_hash, label, now() + valid_for)
  RETURNING id INTO new_id;
  RETURN new_id;
END; $$;

COMMENT ON FUNCTION rotate_session(text, text, interval) IS
  'Returns null rather than raising, because a refresh with a stale token is an ordinary
   thing that happens to a client that has been offline, and it is answered with a sign-in
   screen rather than an error page.';


-- Definer, and the authorisation is knowing the digest: a caller who has it either holds
-- the token or has the database, and in the second case a revocation is not the problem.
CREATE OR REPLACE FUNCTION revoke_session(target_hash text)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, public AS $$
DECLARE n integer;
BEGIN
  -- Only sessions that could still be used. Revoking one that had already timed out would
  -- record that somebody took it away, which is not what happened, and a reviewer asking
  -- why a session ended is owed the difference.
  UPDATE sessions SET revoked_at = now()
  WHERE refresh_hash = target_hash AND revoked_at IS NULL AND expires_at > now();
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END; $$;

-- Sign out everywhere. Used when a password changes, and when somebody reports a lost
-- phone, which is the case it exists for.
-- Definer, and this one takes a user id rather than a digest - so without a check it
-- would let the application sign anybody out, which is a denial of service against a
-- caregiver mid-shift and a way to force somebody onto a phishing page at the same time.
--
-- Signing out everywhere is a thing a person does to themselves. Ending somebody else's
-- access is a workforce act and goes through users.deactivated_at, where a trigger closes
-- the sessions and the audit trail records who did it.
CREATE OR REPLACE FUNCTION revoke_all_sessions(target_user uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, public AS $$
DECLARE n integer;
BEGIN
  IF nullif(current_setting('app.user_id', true), '')::uuid IS DISTINCT FROM target_user THEN
    RAISE EXCEPTION 'a session can only be ended everywhere by the person in it'
      USING ERRCODE = 'insufficient_privilege',
            HINT = 'Ending somebody else''s access is users.deactivated_at.';
  END IF;

  UPDATE sessions SET revoked_at = now()
  WHERE user_id = target_user AND revoked_at IS NULL AND expires_at > now();
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END; $$;


-- Deactivating an account signs it out everywhere, as one act rather than two. A
-- termination procedure that has to remember the second step is a procedure that will
-- eventually forget it, and the failure is silent: the account is closed and the phone
-- still works.
CREATE OR REPLACE FUNCTION end_sessions_on_deactivation() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
BEGIN
  IF NEW.deactivated_at IS NOT NULL AND OLD.deactivated_at IS NULL THEN
    UPDATE sessions SET revoked_at = now()
    WHERE user_id = NEW.id AND revoked_at IS NULL AND expires_at > now();
  END IF;
  RETURN NEW;
END; $$;

CREATE TRIGGER deactivation_ends_sessions
  AFTER UPDATE OF deactivated_at ON users
  FOR EACH ROW EXECUTE FUNCTION end_sessions_on_deactivation();


-- Called on every authenticated request. One statement, so a session that is being used
-- stays alive and one that is not does not.
CREATE OR REPLACE FUNCTION touch_session(candidate_hash text, idle_for interval DEFAULT interval '12 hours')
RETURNS void LANGUAGE sql SECURITY DEFINER
  SET search_path = pg_catalog, public AS $$
  UPDATE sessions SET last_used_at = now(), idle_expires_at = now() + idle_for
  WHERE refresh_hash = candidate_hash AND revoked_at IS NULL
$$;

COMMENT ON FUNCTION touch_session(text, interval) IS
  'Twelve hours by default, which is a shift and a bit. Long enough that a caregiver coming
   back after a break does not sign in again, short enough that a phone left on a med cart
   overnight is not a way in.';


-- ════════════════════════════════════════════════════════════════════ single-use tokens
--
-- Invitations, password resets and email verification. All three are bearer credentials
-- that arrive in an inbox, so all three are stored as digests and all three are consumed
-- exactly once.

-- Definer. Knowing the digest is the authorisation, and the UPDATE is what makes it
-- single-use, so a second caller with the same token gets nothing rather than a race.
CREATE OR REPLACE FUNCTION consume_token(candidate_hash text, for_purpose text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, public AS $$
DECLARE owner uuid;
BEGIN
  -- The condition and the write are one statement. Two concurrent requests with the same
  -- link cannot both pass, whatever order they arrive in, because the second finds no row
  -- with consumed_at still null.
  UPDATE user_tokens SET consumed_at = now()
  WHERE token_hash  = candidate_hash
    AND purpose     = for_purpose
    AND consumed_at IS NULL
    AND expires_at  > now()
  RETURNING user_id INTO owner;

  RETURN owner;   -- null when it was already used, expired, or for something else
END; $$;

COMMENT ON FUNCTION consume_token(text, text) IS
  'Checking and then updating would be two statements and a race. An invitation link
   forwarded to a whole family, or double-tapped on a bad connection, admits one person.';


-- Redeeming a link: the token is spent and the password is set, or neither happens.
--
-- consume_token stops half way. It tells the caller whose link it was, and the caller then
-- has to write the password - which the application cannot do and should not be able to.
-- Its UPDATE on users is display_name and updated_at, deliberately, because an application
-- that can write password_hash can write anybody's. So an invitation could be accepted and
-- the account it belonged to still had no way in. The flow was designed to this point and
-- stopped.
--
-- Both halves are here, in one transaction, for the same reason consume_token is one
-- statement. A token spent against an account whose password was never written is a
-- caregiver holding a link that looks used and does not work, with nothing to do about it.
--
-- The purpose is passed in rather than guessed: an invitation and a reset both end with a
-- password, but they are different events and the row says which one happened.
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

  RETURN owner;
END; $$;

COMMENT ON FUNCTION redeem_token(text, text, text) IS
  'The whole of accepting an invitation or a reset. Handed out to the application because
   it cannot be used for anything else: it writes one password, for the one account the
   token names, and only while that token is unused and unexpired. The application''s own
   UPDATE on users stays display_name and updated_at.';


-- ════════════════════════════════════════════════════════════════════ what a reviewer asks
--
-- Sessions per user and per device, which is the answer to "can one person be signed in on
-- two phones" and to "what happens when they lose one".

CREATE VIEW session_inventory AS
SELECT u.id AS user_id, u.email,
       count(*) FILTER (WHERE s.revoked_at IS NULL AND s.expires_at > now()) AS active,
       count(*) FILTER (WHERE s.revoked_at IS NOT NULL) AS revoked,
       count(*) FILTER (WHERE s.revoked_at IS NULL AND s.expires_at <= now()) AS expired,
       max(s.last_used_at) AS last_seen
FROM users u LEFT JOIN sessions s ON s.user_id = u.id
GROUP BY u.id, u.email;

CREATE VIEW stale_invitations AS
SELECT t.id, t.user_id, t.purpose, t.expires_at
FROM user_tokens t
WHERE t.consumed_at IS NULL AND t.expires_at < now();

COMMENT ON VIEW session_inventory IS
  'An operator view. Deliberately not granted to the application: it runs as its owner and
   would return every user at every facility, which is exactly what the policies on
   sessions exist to prevent.';

COMMENT ON VIEW stale_invitations IS
  'Not an error. An invitation nobody accepted expires, and the row stays so that a manager
   can see they invited somebody who never arrived.';


DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dailycare_app') THEN
    -- EXECUTE on a function that is not a definer buys nothing: the body still runs as
    -- the caller, and the application holds no write on sessions. These grants were here
    -- and every one of them was inert - signing in, refreshing, signing out and accepting
    -- an invitation all failed with permission denied on a real database. The functions
    -- are definers now, each with the check that makes handing it out safe.
    GRANT EXECUTE ON FUNCTION start_session(uuid, text, text, interval, interval) TO dailycare_app;
    GRANT EXECUTE ON FUNCTION session_owner(text)                       TO dailycare_app;
    GRANT EXECUTE ON FUNCTION session_is_valid(text)                    TO dailycare_app;
    GRANT EXECUTE ON FUNCTION rotate_session(text, text, interval)      TO dailycare_app;
    GRANT EXECUTE ON FUNCTION revoke_session(text)                      TO dailycare_app;
    GRANT EXECUTE ON FUNCTION revoke_all_sessions(uuid)                 TO dailycare_app;
    GRANT EXECUTE ON FUNCTION consume_token(text, text)                 TO dailycare_app;
    GRANT EXECUTE ON FUNCTION redeem_token(text, text, text)           TO dailycare_app;
    -- Not session_inventory, and not stale_invitations. A view runs with its owner's
    -- privileges in PostgreSQL 14, so granting one to the application is a way around
    -- every policy on the table underneath it: session_inventory lists every user's
    -- sessions at every facility, and the application cannot read sessions at all.
    -- They are operator views. What a person needs is their own devices, and the policy
    -- on sessions gives them that directly.
    REVOKE ALL ON session_inventory, stale_invitations FROM dailycare_app;
  END IF;
END $$;
