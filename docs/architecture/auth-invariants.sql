-- Authentication checks for authentication.sql
--
-- Run by verify.sh. See README.md for the manual sequence.
--
-- Two of these are the milestone's own acceptance criteria rather than a design opinion:
-- that a caregiver who reinstalls the app and signs back in finds their records, and that
-- two authorised devices see the same facility. Both are stated as things somebody can
-- watch happen rather than as a sentence in a document.

\set QUIET on
SET client_min_messages TO notice;

-- Lift FORCE for this suite so that it behaves the same run by a superuser and run by a
-- managed-instance owner. See checks-support.sql.
SELECT checks_begin();

CREATE OR REPLACE FUNCTION expect(label text, condition boolean) RETURNS void AS $$
BEGIN
  IF condition THEN RAISE NOTICE 'PASS  %', label;
  ELSE            RAISE NOTICE 'FAIL  %', label;
  END IF;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION expect_rejected(label text, stmt text) RETURNS void AS $$
BEGIN
  BEGIN
    EXECUTE stmt;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'PASS  refused: %', label; RETURN;
  END;
  RAISE NOTICE 'FAIL  ALLOWED, and should not have been: %', label;
END; $$ LANGUAGE plpgsql;

-- Digests, the shape the columns demand. The tokens themselves never exist here, which is
-- the point of the columns demanding it.
CREATE OR REPLACE FUNCTION h(token text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$ SELECT md5('a' || token) || md5(token || 'b') $$;

INSERT INTO facilities (id, name, timezone) VALUES
  ('f1000000-0000-0000-0000-000000000001', 'Cedar House', 'America/Chicago');
INSERT INTO users (id, email, display_name) VALUES
  ('a0000000-0000-0000-0000-00000000000a', 'maria@example.test', 'Maria'),
  ('c0000000-0000-0000-0000-00000000000c', 'anna@example.test',  'Anna');
INSERT INTO facility_members (id, facility_id, user_id, role, state) VALUES
  ('fa000000-0000-0000-0000-00000000000a', 'f1000000-0000-0000-0000-000000000001',
   'a0000000-0000-0000-0000-00000000000a', 'caregiver', 'active');
INSERT INTO residents (id, facility_id, display_name) VALUES
  ('e1000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000001', 'Cathy');
INSERT INTO assignments (facility_id, resident_id, facility_member_id) VALUES
  ('f1000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001',
   'fa000000-0000-0000-0000-00000000000a');
INSERT INTO care_days (id, facility_id, resident_id, care_date, mood, appetite, sleep, filed_by)
VALUES ('cd000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000001',
        'e1000000-0000-0000-0000-000000000001', current_date, 'calm', 'good', 'restless',
        'a0000000-0000-0000-0000-00000000000a');
\set QUIET off


-- ── a session is valid, or it is not ───────────────────────────────────────────

\echo ''
\echo '── sessions'

\set QUIET on
INSERT INTO sessions (user_id, refresh_hash, device_label, expires_at) VALUES
  ('a0000000-0000-0000-0000-00000000000a', h('phone'),  'iPhone 15', now() + interval '30 days'),
  ('a0000000-0000-0000-0000-00000000000a', h('tablet'), 'iPad',      now() + interval '30 days'),
  ('a0000000-0000-0000-0000-00000000000a', h('old'),    'old phone', now() - interval '1 day');
\set QUIET off

SELECT expect('a session issued today is valid',        session_is_valid(h('phone')));
SELECT expect('one that has run out is not',        NOT session_is_valid(h('old')));
SELECT expect('and a token nobody issued is not',   NOT session_is_valid(h('invented')));

\set QUIET on
SELECT revoke_session(h('phone'));
\set QUIET off
SELECT expect('a revoked session stops working',    NOT session_is_valid(h('phone')));

SELECT expect('and revoking one device leaves the other signed in',
  session_is_valid(h('tablet')));

\set QUIET on
INSERT INTO sessions (user_id, refresh_hash, device_label, expires_at)
VALUES ('a0000000-0000-0000-0000-00000000000a', h('phone2'), 'iPhone 15', now() + interval '30 days');
\set QUIET off

SELECT expect('signing out everywhere takes both live sessions and leaves the expired one alone',
  (SELECT revoke_all_sessions('a0000000-0000-0000-0000-00000000000a') = 2));

SELECT expect('so a session that timed out still reads as expired rather than revoked',
  (SELECT revoked_at IS NULL FROM sessions WHERE refresh_hash = h('old')));

SELECT expect('and leaves nothing active',
  (SELECT active = 0 FROM session_inventory
   WHERE user_id = 'a0000000-0000-0000-0000-00000000000a'));


-- ── rotation ───────────────────────────────────────────────────────────────────

\echo ''
\echo '── refreshing'

\set QUIET on
INSERT INTO sessions (user_id, refresh_hash, device_label, expires_at)
VALUES ('a0000000-0000-0000-0000-00000000000a', h('r1'), 'iPhone 15', now() + interval '30 days');
\set QUIET off

SELECT expect('a refresh issues a new session',
  (SELECT rotate_session(h('r1'), h('r2')) IS NOT NULL));

SELECT expect('the new one works',        session_is_valid(h('r2')));
SELECT expect('and the old one does not, so a stolen refresh token dies on first use',
  NOT session_is_valid(h('r1')));

SELECT expect('it keeps the device it belongs to, so the user still recognises the row',
  (SELECT device_label = 'iPhone 15' FROM sessions WHERE refresh_hash = h('r2')));

SELECT expect('refreshing with the stale token returns nothing rather than raising',
  (SELECT rotate_session(h('r1'), h('r3')) IS NULL));

SELECT expect('and that failed attempt issued nothing',
  NOT session_is_valid(h('r3')));


-- ── single-use tokens ──────────────────────────────────────────────────────────

\echo ''
\echo '── invitations and resets'

\set QUIET on
INSERT INTO user_tokens (user_id, purpose, token_hash, expires_at) VALUES
  ('c0000000-0000-0000-0000-00000000000c', 'invitation',     h('invite'), now() + interval '7 days'),
  ('c0000000-0000-0000-0000-00000000000c', 'password_reset', h('reset'),  now() + interval '1 hour'),
  ('c0000000-0000-0000-0000-00000000000c', 'invitation',     h('stale'),  now() - interval '1 day');
\set QUIET off

SELECT expect('an invitation admits the person it was sent to',
  (SELECT consume_token(h('invite'), 'invitation')
          = 'c0000000-0000-0000-0000-00000000000c'));

SELECT expect('the same link a second time admits nobody',
  (SELECT consume_token(h('invite'), 'invitation') IS NULL));

SELECT expect('an expired invitation admits nobody',
  (SELECT consume_token(h('stale'), 'invitation') IS NULL));

SELECT expect('a reset link cannot be redeemed as an invitation',
  (SELECT consume_token(h('reset'), 'invitation') IS NULL));

SELECT expect('but it still works as what it is',
  (SELECT consume_token(h('reset'), 'password_reset')
          = 'c0000000-0000-0000-0000-00000000000c'));

SELECT expect('an invitation nobody accepted is visible rather than lost',
  (SELECT count(*) = 1 FROM stale_invitations
   WHERE user_id = 'c0000000-0000-0000-0000-00000000000c' AND purpose = 'invitation'));

SELECT expect_rejected('storing an invitation token as it was sent', $$
  INSERT INTO user_tokens (user_id, purpose, token_hash, expires_at)
  VALUES ('c0000000-0000-0000-0000-00000000000c', 'invitation', 'dc-invite-9f2a7c4e',
          now() + interval '7 days')
$$);


-- ── a person who has left ──────────────────────────────────────────────────────
--
-- From an independent review. session_is_valid() checked the session and nothing about
-- the person, and users.deactivated_at said "sign-in refused" rather than "signed out" -
-- so a termination ended a membership, closed an account, and left the phone working for
-- the remaining life of the refresh token.

\echo ''
\echo '── somebody who has been deactivated'

\set QUIET on
INSERT INTO users (id, email, display_name) VALUES
  ('d0000000-0000-0000-0000-00000000000d', 'leaving@example.test', 'Deborah');
INSERT INTO sessions (user_id, refresh_hash, device_label, expires_at) VALUES
  ('d0000000-0000-0000-0000-00000000000d', h('her_phone'), 'her phone', now() + interval '30 days');
\set QUIET off

SELECT expect('her session works while she is employed', session_is_valid(h('her_phone')));

\set QUIET on
UPDATE users SET deactivated_at = now() WHERE id = 'd0000000-0000-0000-0000-00000000000d';
\set QUIET off

SELECT expect('deactivating the account stops it, without anybody remembering a second step',
  NOT session_is_valid(h('her_phone')));

SELECT expect('and the row says it was revoked rather than left to expire',
  (SELECT revoked_at IS NOT NULL FROM sessions WHERE refresh_hash = h('her_phone')));

SELECT expect('refreshing with it issues nothing',
  (SELECT rotate_session(h('her_phone'), h('her_phone_2')) IS NULL)
  AND NOT session_is_valid(h('her_phone_2')));


-- ── the milestone's own acceptance criteria ────────────────────────────────────
--
-- "authorized data persists across reinstall/sign-in" and "authorized caregivers on
-- separate devices access the appropriate shared facility/resident data". Both are worth
-- proving rather than asserting, because both are about what a caregiver sees rather than
-- about what a table contains.

\echo ''
\echo '── reinstalling the app, and using two of them'

\set QUIET on
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dailycare_app') THEN
    RAISE EXCEPTION 'role dailycare_app does not exist. Apply roles.sql first.';
  END IF;
END $$;
GRANT USAGE ON SCHEMA public TO dailycare_app;
-- No blanket grant here. grants.sql is the baseline and these checks run against it,
-- so what the application may touch is the same in a suite as in production.
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO dailycare_app;

-- Maria reinstalls. Everything local is gone; she signs in and gets a new session.
SELECT revoke_all_sessions('a0000000-0000-0000-0000-00000000000a');
INSERT INTO sessions (user_id, refresh_hash, device_label, expires_at)
VALUES ('a0000000-0000-0000-0000-00000000000a', h('reinstalled'), 'iPhone 15 (new)',
        now() + interval '30 days');
\set QUIET off

SELECT expect('the new install has a working session and the old ones are gone',
  session_is_valid(h('reinstalled'))
  AND (SELECT active = 1 FROM session_inventory
       WHERE user_id = 'a0000000-0000-0000-0000-00000000000a'));

SET ROLE dailycare_app;
SELECT set_config('app.user_id', 'a0000000-0000-0000-0000-00000000000a', false) \gset
SELECT expect('and the care day she filed before the reinstall is still hers to read',
  (SELECT count(*) = 1 FROM care_days
   WHERE id = 'cd000000-0000-0000-0000-000000000001'));
RESET ROLE;

-- The second device. A different session, the same person, the same building.
\set QUIET on
INSERT INTO sessions (user_id, refresh_hash, device_label, expires_at)
VALUES ('a0000000-0000-0000-0000-00000000000a', h('second_device'), 'facility iPad',
        now() + interval '30 days');
\set QUIET off

SELECT expect('a second authorised device is a second session, not a second account',
  session_is_valid(h('second_device'))
  AND (SELECT active = 2 FROM session_inventory
       WHERE user_id = 'a0000000-0000-0000-0000-00000000000a'));

SET ROLE dailycare_app;
SELECT set_config('app.user_id', 'a0000000-0000-0000-0000-00000000000a', false) \gset
SELECT expect('and it reads the same resident and the same day',
  (SELECT count(*) = 1 FROM residents WHERE id = 'e1000000-0000-0000-0000-000000000001')
  AND (SELECT count(*) = 1 FROM care_days));
RESET ROLE;

-- And the lost phone, which is the case sign-out-everywhere exists for.
\set QUIET on
SELECT revoke_session(h('second_device'));
\set QUIET off
SELECT expect('losing the second device does not sign her out of the first',
  session_is_valid(h('reinstalled')) AND NOT session_is_valid(h('second_device')));

\echo ''
\echo '── signing in, which is the step the policies cannot help with'

-- Every read policy on users needs app_user_id(), and sign-in is what produces one. Before
-- credential_for_sign_in existed the application saw zero rows for any address, which a
-- real database confirmed when it was asked: nobody could sign in at all.
--
-- The fixtures above carry no digests, because nothing until now needed one.
--
-- And the identity is cleared first: earlier checks in this file set one session-wide, and
-- credential_for_sign_in refuses while anybody is identified - which is the point of it.
-- Arriving here still identified made four of these read as errors rather than answers.
\set QUIET on
SELECT set_config('app.user_id', '', false);
INSERT INTO users (id, email, display_name, password_hash) VALUES
  ('b0000000-0000-0000-0000-00000000000b', 'signing@example.test', 'Sandra',
   '$argon2id$v=19$m=19456,t=2,p=1$YWJjZGVmZ2hpamtsbW5vcA$aGFzaGhhc2hoYXNoaGFzaGhhc2hoYXNoaGFzaGhhcw'),
  ('b1000000-0000-0000-0000-00000000001b', 'fired@example.test', 'Frank',
   '$argon2id$v=19$m=19456,t=2,p=1$YWJjZGVmZ2hpamtsbW5vcA$aGFzaGhhc2hoYXNoaGFzaGhhc2hoYXNoaGFzaGhhcw');
UPDATE users SET deactivated_at = now() WHERE id = 'b1000000-0000-0000-0000-00000000001b';
\set QUIET off

SELECT expect('the application can find a credential with nobody identified',
  (SELECT count(*) = 1 FROM credential_for_sign_in('signing@example.test')));

SELECT expect('and an address nobody has answers the same way an absent one does',
  (SELECT count(*) = 0 FROM credential_for_sign_in('nobody@example.test')));

-- A termination closes the door here rather than leaving it to a handler afterwards.
SELECT expect('a deactivated account has no credential to find',
  (SELECT count(*) = 0 FROM credential_for_sign_in('fired@example.test')));

-- An invitation that was sent and never accepted has no digest, and must not be a way in.
SELECT expect('and neither does an invitation nobody accepted',
  (SELECT count(*) = 0 FROM credential_for_sign_in('maria@example.test')));

-- The narrowing that makes the function safe to grant at all. An identified request has no
-- business asking for a digest, so the route to one is open only in the moment before there
-- is a session. Without this line the function is a hash-extraction tool for whoever gets a
-- session first.
\set QUIET on
SELECT set_config('app.user_id', 'b0000000-0000-0000-0000-00000000000b', false);
\set QUIET off

SELECT expect_rejected('and it refuses once anybody is identified',
  $$SELECT * FROM credential_for_sign_in('signing@example.test')$$);

\set QUIET on
SELECT set_config('app.user_id', '', false);
\set QUIET off

-- And the identity really is gone again, so nothing below is answering as Sandra.
SELECT expect('and the identity is put back afterwards',
  nullif(current_setting('app.user_id', true), '') IS NULL);

\echo ''
\echo '── and the digest is not reachable any other way'

-- data_classification has said "Never returned, never logged" about password_hash since the
-- beginning, and until the grant was narrowed that was a property of whichever handler last
-- touched it: a session could read its own digest through users_self.
SELECT expect('the application is not granted the password column',
  (SELECT count(*) = 0 FROM information_schema.role_column_grants
   WHERE grantee = 'dailycare_app' AND table_name = 'users'
     AND column_name = 'password_hash'));

SELECT expect('but is granted the rest of the row',
  (SELECT count(*) >= 8 FROM information_schema.role_column_grants
   WHERE grantee = 'dailycare_app' AND table_name = 'users'
     AND privilege_type = 'SELECT'));

-- A table-level grant is every column, and revoking one afterwards does not narrow it. So
-- the absence of that grant is the thing that makes the column grant mean anything.
SELECT expect('and no table-level grant on users quietly puts it back',
  (SELECT count(*) = 0 FROM information_schema.role_table_grants
   WHERE grantee = 'dailycare_app' AND table_name = 'users'
     AND privilege_type = 'SELECT'));

\echo ''
\echo '   sessions on record:'
SELECT email, active, revoked, expired FROM session_inventory ORDER BY email;

\set QUIET on
SELECT checks_end();
DROP FUNCTION expect(text, boolean);
DROP FUNCTION expect_rejected(text, text);
DROP FUNCTION h(text);
\set QUIET off
