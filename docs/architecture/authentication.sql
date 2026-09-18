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


-- ════════════════════════════════════════════════════════════════════ sessions

CREATE OR REPLACE FUNCTION session_is_valid(candidate_hash text)
RETURNS boolean LANGUAGE sql STABLE
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


-- Refresh rotation. The old session is revoked in the same statement that issues the new
-- one, so a stolen refresh token stops working the moment the real client uses theirs.
CREATE OR REPLACE FUNCTION rotate_session(
  old_hash    text,
  new_hash    text,
  valid_for   interval DEFAULT interval '30 days'
) RETURNS uuid LANGUAGE plpgsql
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


CREATE OR REPLACE FUNCTION revoke_session(target_hash text)
RETURNS integer LANGUAGE plpgsql
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
CREATE OR REPLACE FUNCTION revoke_all_sessions(target_user uuid)
RETURNS integer LANGUAGE plpgsql
  SET search_path = pg_catalog, public AS $$
DECLARE n integer;
BEGIN
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

CREATE OR REPLACE FUNCTION consume_token(candidate_hash text, for_purpose text)
RETURNS uuid LANGUAGE plpgsql
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
    GRANT EXECUTE ON FUNCTION session_is_valid(text)                    TO dailycare_app;
    GRANT EXECUTE ON FUNCTION rotate_session(text, text, interval)      TO dailycare_app;
    GRANT EXECUTE ON FUNCTION revoke_session(text)                      TO dailycare_app;
    GRANT EXECUTE ON FUNCTION revoke_all_sessions(uuid)                 TO dailycare_app;
    GRANT EXECUTE ON FUNCTION consume_token(text, text)                 TO dailycare_app;
    -- Not session_inventory, and not stale_invitations. A view runs with its owner's
    -- privileges in PostgreSQL 14, so granting one to the application is a way around
    -- every policy on the table underneath it: session_inventory lists every user's
    -- sessions at every facility, and the application cannot read sessions at all.
    -- They are operator views. What a person needs is their own devices, and the policy
    -- on sessions gives them that directly.
    REVOKE ALL ON session_inventory, stale_invitations FROM dailycare_app;
  END IF;
END $$;
