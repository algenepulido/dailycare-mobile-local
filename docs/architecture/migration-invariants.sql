-- Checks on migrate.sh and what it leaves behind.
--
-- The database these run against was built by migrate.sh, because verify.sh uses it. So a
-- broken runner takes every suite down with it and these are about what the record says
-- afterwards: that the model went in whole, and that nothing which runs the application can
-- edit the record of what went in.

\set QUIET on
SET client_min_messages TO notice;
SELECT checks_begin();

CREATE OR REPLACE FUNCTION expect(label text, condition boolean) RETURNS void AS $$
BEGIN
  IF condition THEN RAISE NOTICE 'PASS  %', label;
  ELSE            RAISE NOTICE 'FAIL  %', label;
  END IF;
END; $$ LANGUAGE plpgsql;

-- Tries it and wants to be told no. A refusal for any other reason than privilege is not a
-- pass: a typo in the statement would otherwise read as the protection working.
CREATE OR REPLACE FUNCTION refuses(label text, who text, stmt text) RETURNS void AS $$
BEGIN
  BEGIN
    EXECUTE format('SET LOCAL ROLE %I', who);
    EXECUTE stmt;
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS  refused: %', label;
    RETURN;
  END;
  RAISE NOTICE 'FAIL  ALLOWED, and should not have been: %', label;
END; $$ LANGUAGE plpgsql;
\set QUIET off

\echo ''
\echo '── the model went in whole'

SELECT expect('there is a record at all',
  (SELECT count(*) > 0 FROM schema_migrations));

-- A gap means a file was applied outside migrate.sh, or one was removed from the list
-- after a database had already had it. Either way the database is not the model any more.
SELECT expect('the positions run from one with no gaps',
  (SELECT count(*) = max(position) AND min(position) = 1 FROM schema_migrations));

SELECT expect('no file went in twice',
  (SELECT count(*) = count(DISTINCT filename) FROM schema_migrations));

SELECT expect('the last thing applied is the last thing in the list',
  (SELECT filename = 'grants.sql' FROM schema_migrations ORDER BY position DESC LIMIT 1));

SELECT expect('every row carries the digest of the file as applied',
  (SELECT bool_and(sha256 ~ '^[0-9a-f]{64}$') FROM schema_migrations));

SELECT expect('and says who applied it',
  (SELECT bool_and(applied_by IS NOT NULL AND applied_by <> '') FROM schema_migrations));

\echo ''
\echo '── and nothing that runs the application can edit the record of it'

-- The point. An audit trail that the audited party can rewrite is a log, not a trail, and
-- the same is true of a migration record: if the application can add a row, then a database
-- can claim to be the reviewed model without being it.
SELECT refuses('the application cannot add a migration', 'dailycare_app',
  $$INSERT INTO schema_migrations (position, filename, sha256) VALUES (999, 'made-up.sql', repeat('0',64))$$);

SELECT refuses('the application cannot rewrite one', 'dailycare_app',
  $$UPDATE schema_migrations SET sha256 = repeat('0',64)$$);

SELECT refuses('the application cannot remove one', 'dailycare_app',
  $$DELETE FROM schema_migrations$$);

-- Retention deletes things for a living, on a schedule, unattended. This must not be one of
-- the things it deletes.
SELECT refuses('and neither can retention, which deletes for a living', 'dailycare_retention',
  $$DELETE FROM schema_migrations$$);

\echo ''
\echo '── and the record itself holds nothing worth protecting'

-- If any of this were ever classified above operational, the record would have become
-- something that needs scrubbing before a copy leaves production, and a migration record
-- that cannot travel with a restored database is not much use.
SELECT expect('nothing in the migration record is about a person',
  (SELECT bool_and(class = 'operational') FROM data_classification
   WHERE table_name = 'schema_migrations'));

SELECT expect('and every column of it is classified',
  (SELECT count(*) = 0 FROM information_schema.columns c
   WHERE c.table_schema = 'public' AND c.table_name = 'schema_migrations'
     AND NOT EXISTS (SELECT 1 FROM data_classification d
                     WHERE d.table_name = 'schema_migrations'
                       AND d.column_name = c.column_name)));

SELECT checks_end();
