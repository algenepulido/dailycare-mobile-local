-- Automatic logoff, which the model declared and rotation quietly undid.
--
-- A session carries two deadlines and they answer different questions. expires_at is how
-- long somebody may stay signed in at all; idle_expires_at is how long a phone left on a
-- med cart in a corridor stays useful. session_is_valid and session_owner have read both
-- since they were written.
--
-- rotate_session read only the first, and the row it wrote carried neither - no idle
-- limit, and a fresh thirty days rather than the deadline it came from. So a client that
-- keeps refreshing never goes idle, and its absolute expiry walks forward with it. Nobody
-- was ever logged off automatically, which is what §164.312(a)(2)(iii) asks for.
--
-- Three changes, and they are the whole of it.
--
--   The WHERE clause asks the idle question as well, so a session that has already gone
--   idle cannot be refreshed back to life. This is the half that matters: without it the
--   other two only shorten a window that could still be reopened.
--
--   The new row inherits the old row's expires_at instead of being given a new one.
--   Rotation is a token being replaced, not a session being started, and a token that
--   could extend its own deadline indefinitely is not a deadline.
--
--   The new row gets an idle window of its own.
--
-- On that last one: touch_session exists to advance the idle clock on every authenticated
-- request and is called from nowhere, which the same review noticed. This does not add
-- that call, and does not need it. The client refreshes when its access token runs out,
-- which happens because it is being used - so rotation is the proof of life, and setting
-- the window here is what makes the idle clock run at all. Calling touch_session per
-- request would make it finer-grained, not make it work.
--
-- The signature is unchanged on purpose. The third argument is renamed, which PostgreSQL
-- will not do in place, so the function is dropped and recreated - and because the types
-- are the same the grant below is the same line it always was.

DROP FUNCTION IF EXISTS rotate_session(text, text, interval);

CREATE FUNCTION rotate_session(
  old_hash    text,
  new_hash    text,
  idle_for    interval DEFAULT interval '12 hours'
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = pg_catalog, public AS $$
DECLARE
  owner    uuid;
  label    text;
  deadline timestamptz;
  new_id   uuid;
BEGIN
  UPDATE sessions SET revoked_at = now()
  WHERE refresh_hash = old_hash AND revoked_at IS NULL AND expires_at > now()
    AND (idle_expires_at IS NULL OR idle_expires_at > now())
    AND user_id IN (SELECT id FROM users WHERE deactivated_at IS NULL)
  RETURNING user_id, device_label, expires_at INTO owner, label, deadline;

  IF owner IS NULL THEN
    RETURN NULL;   -- unknown, revoked, expired or idle. The caller signs in again.
  END IF;

  INSERT INTO sessions (user_id, refresh_hash, device_label, expires_at, idle_expires_at)
  VALUES (owner, new_hash, label, deadline, now() + idle_for)
  RETURNING id INTO new_id;
  RETURN new_id;
END; $$;

COMMENT ON FUNCTION rotate_session(text, text, interval) IS
  'Returns null rather than raising, because a refresh with a stale token is an ordinary
   thing that happens to a client that has been offline, and it is answered with a sign-in
   rather than with an error. Null now also means the session went idle, which reads the
   same way to a caller and is the point: a phone that was left somewhere signs in again.';

GRANT EXECUTE ON FUNCTION rotate_session(text, text, interval) TO dailycare_app;
