-- Accepting an invitation activates the grant it was sent for.
--
-- A new file because migrate.sh pins an applied one by digest. Correct against a database
-- built a moment ago and against one running since September: CREATE OR REPLACE replaces
-- the function either way, and the statement it adds matches no rows on an instance that
-- has never had a family member.

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
  UPDATE resident_contacts
     SET state = 'active', updated_at = now()
   WHERE user_id = owner AND state = 'invited';

  RETURN owner;
END; $$;
