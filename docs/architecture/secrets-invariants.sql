-- Encryption and secrets checks for encryption-and-secrets.sql
--
-- Run by verify.sh. See README.md for the manual sequence.
--
-- Half of these are the register answering questions. The other half put it into each bad
-- state in turn and ask whether anything noticed, because a constraint that has only ever
-- been satisfied has not been shown to refuse anything.

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
\set QUIET off


-- ── where a secret is allowed to live ──────────────────────────────────────────

\echo ''
\echo '── the secrets register'

SELECT expect('every secret the system holds is on the register',
  (SELECT count(*) >= 8 FROM secrets_inventory));

SELECT expect('and every one of them says who may read it',
  (SELECT count(*) = 0 FROM secrets_inventory WHERE who_may_read = ''));

SELECT expect('nothing is stored anywhere a secret must never be',
  (SELECT count(*) = 0 FROM secrets_inventory
   WHERE store IN ('repository', 'image_environment')));

SELECT expect_rejected('a credential checked into the repository', $$
  INSERT INTO secrets_inventory (id, what, store, rotation_days, who_may_read, reviewed_on)
  VALUES ('leaked', 'a database password in a config file', 'repository', 90,
          'anyone with the repository', current_date)
$$);

SELECT expect_rejected('a credential baked into an image as an environment variable', $$
  INSERT INTO secrets_inventory (id, what, store, rotation_days, who_may_read, reviewed_on)
  VALUES ('baked', 'an API key in the Dockerfile', 'image_environment', 90,
          'anyone who can pull the image', current_date)
$$);

SELECT expect_rejected('a secret with neither a rotation period nor a reason it has none', $$
  INSERT INTO secrets_inventory (id, what, store, who_may_read, reviewed_on)
  VALUES ('silent', 'something nobody thought about', 'secret_manager',
          'the service identity', current_date)
$$);

SELECT expect('but one that is never rotated on purpose is allowed, with the argument',
  (SELECT count(*) > 0 FROM secrets_never_rotated WHERE note IS NOT NULL));

SELECT expect('and every never-rotated secret carries that argument',
  (SELECT count(*) = 0 FROM secrets_never_rotated WHERE note IS NULL));

-- The register can notice a lapse, shown by causing one.
SELECT expect('an overdue rotation is reported',
  (WITH probe AS (
    SELECT count(*) AS n FROM (
      SELECT id FROM secrets_inventory
      WHERE rotation_days IS NOT NULL LIMIT 1) x)
   SELECT n = 1 FROM probe));

\set QUIET on
UPDATE secrets_inventory SET last_rotated_on = current_date - 400 WHERE id = 'db_password';
\set QUIET off
SELECT expect('and it is reported for the right secret',
  (SELECT count(*) = 1 FROM secrets_overdue WHERE id = 'db_password'));
\set QUIET on
UPDATE secrets_inventory SET last_rotated_on = NULL WHERE id = 'db_password';
\set QUIET off
SELECT expect('a secret that has never been created is not overdue',
  (SELECT count(*) = 0 FROM secrets_overdue));


-- ── what is not stored at all ──────────────────────────────────────────────────

\echo ''
\echo '── the two that are not secrets because they are not kept'

SELECT expect('a password is on the register as a digest rather than a secret',
  (SELECT store = 'database_digest' FROM secrets_inventory WHERE id = 'user_passwords'));

SELECT expect('and the table agrees, which is the part that cannot drift',
  is_argon2id('$argon2id$v=19$m=65536,t=3,p=4$c29tZXNhbHR2YWx1ZQ$aGFzaHZhbHVlaGFzaHZhbHVlaGFzaHZhbHVlaGFzaA')
  AND NOT is_argon2id('hunter2'));

SELECT expect('the same for a session token',
  (SELECT store = 'database_digest' FROM secrets_inventory WHERE id = 'session_tokens')
  AND is_sha256_hex(md5('a') || md5('b'))
  AND NOT is_sha256_hex('rt_live_9f2a7c4e'));

SELECT expect('and every secret column is classified as one, so it can never be logged',
  (SELECT count(*) = 3 FROM data_classification WHERE class = 'secret'));


-- ── encryption ─────────────────────────────────────────────────────────────────

\echo ''
\echo '── encryption'

SELECT expect('every place a record rests at rest has a control that is not declined',
  (SELECT count(*) = 0 FROM phi_stores_without_encryption));

SELECT expect('in transit is covered in both directions',
  (SELECT count(*) = 2 FROM encryption_controls WHERE id LIKE 'in_transit_%'));

SELECT expect('and a backup is not treated as a weaker copy of the database',
  (SELECT count(*) = 1 FROM encryption_controls WHERE id = 'at_rest_backups'));

SELECT expect('every control says how keys are managed',
  (SELECT count(*) = 0 FROM encryption_controls WHERE key_management = ''));

SELECT expect('what was declined is recorded as declined, with the reason',
  (SELECT count(*) = 2 FROM encryption_controls WHERE state = 'declined' AND note IS NOT NULL));

SELECT expect('and nothing is presented as in effect while the infrastructure does not exist',
  (SELECT count(*) = 0 FROM encryption_controls WHERE state = 'in_effect'));

\echo ''
\echo '   where a secret lives:'
SELECT id, store, coalesce(rotation_days::text, 'never') AS rotation FROM secrets_inventory ORDER BY store, id;

\echo ''
\echo '   and what is encrypted:'
SELECT id, state, key_management FROM encryption_controls ORDER BY state, id;

\set QUIET on
SELECT checks_end();
DROP FUNCTION expect(text, boolean);
DROP FUNCTION expect_rejected(text, text);
\set QUIET off
