-- Backup and recovery checks for backup-recovery.sql and the restore gate
--
--   createdb dc_backup_check
--   psql -v ON_ERROR_STOP=1 -d dc_backup_check -f schema.sql
--   psql -v ON_ERROR_STOP=1 -d dc_backup_check -f access-policies.sql
--   psql -v ON_ERROR_STOP=1 -d dc_backup_check -f data-classification.sql
--   psql -v ON_ERROR_STOP=1 -d dc_backup_check -f audit-logging.sql
--   psql -v ON_ERROR_STOP=1 -d dc_backup_check -f retention.sql
--   psql -v ON_ERROR_STOP=1 -d dc_backup_check -f environments.sql
--   psql -v ON_ERROR_STOP=1 -d dc_backup_check -f vendors.sql
--   psql -v ON_ERROR_STOP=1 -d dc_backup_check -f backup-recovery.sql
--   psql -d dc_backup_check -f backup-invariants.sql
--   dropdb dc_backup_check
--
-- The register is the easy half. The half that matters is the gate: a database restored
-- somewhere other than where it was written serves nothing until it has been scrubbed.
--
-- Here that is simulated by rewriting the identity the deployment row records, which is
-- exactly what a restore does to it. The end-to-end version - dump, restore under another
-- name, query as the application - is restore-drill.sh, and it is a script rather than a
-- check because it needs two databases and a shell.

\set QUIET on
SET client_min_messages TO notice;
-- Lift FORCE for this suite so that it behaves the same run by a superuser and run by a
-- managed-instance owner. See checks-support.sql: the policies stay in force, and every
-- check that tests one does it by becoming the role it is about.
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
    RAISE NOTICE 'PASS  refused (%): %', SQLERRM, label; RETURN;
  END;
  RAISE NOTICE 'FAIL  ALLOWED, and should not have been: %', label;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION expect_noticed(label text, break text, view_name text)
RETURNS void AS $$
DECLARE before_n bigint; after_n bigint;
BEGIN
  EXECUTE format('SELECT count(*) FROM %I', view_name) INTO before_n;
  BEGIN
    EXECUTE break;
    EXECUTE format('SELECT count(*) FROM %I', view_name) INTO after_n;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'PASS  refused outright (%): %', SQLERRM, label; RETURN;
  END;
  IF after_n > before_n THEN RAISE NOTICE 'PASS  % noticed: %', view_name, label;
  ELSE RAISE NOTICE 'FAIL  % did not notice: %', view_name, label;
  END IF;
  RAISE EXCEPTION 'rollback_probe';
EXCEPTION WHEN OTHERS THEN
  IF SQLERRM <> 'rollback_probe' THEN RAISE; END IF;
END; $$ LANGUAGE plpgsql;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dailycare_app') THEN
    RAISE EXCEPTION 'role dailycare_app does not exist. Apply roles.sql first.';
  END IF;
END $$;
GRANT USAGE ON SCHEMA public TO dailycare_app;
-- No blanket grant here. grants.sql is the baseline and these checks run against it,
-- so what the application may touch is the same in a suite as in production.
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO dailycare_app;
REVOKE ALL ON deployment, scrub_rules, scrub_runs, vendors, vendor_exposure,
  backup_policies, restore_drills FROM dailycare_app;
GRANT SELECT ON deployment TO dailycare_app;

INSERT INTO deployment (environment, label) VALUES ('production', 'check');

INSERT INTO facilities (id, name, timezone) VALUES
  ('f1000000-0000-0000-0000-000000000001', 'Cedar House', 'America/Chicago');
INSERT INTO retention_policies (facility_id, care_record_days, media_days, audit_days)
  VALUES ('f1000000-0000-0000-0000-000000000001', 2555, 2555, 2190);
INSERT INTO users (id, email, display_name) VALUES
  ('a0000000-0000-0000-0000-00000000000a', 'maria@cedar.test', 'Maria');
INSERT INTO facility_members (id, facility_id, user_id, role, state) VALUES
  ('fa000000-0000-0000-0000-00000000000a', 'f1000000-0000-0000-0000-000000000001',
   'a0000000-0000-0000-0000-00000000000a', 'care_manager', 'active');
INSERT INTO residents (id, facility_id, display_name) VALUES
  ('e1000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000001', 'Cathy');
INSERT INTO care_days (facility_id, resident_id, care_date, mood, appetite, sleep, note, filed_by)
  VALUES ('f1000000-0000-0000-0000-000000000001','e1000000-0000-0000-0000-000000000001',
          current_date,'agitated','refused','didnt_sleep','She was frightened again tonight.',
          'a0000000-0000-0000-0000-00000000000a');
\set QUIET off


-- ── the register ───────────────────────────────────────────────────────────────

\echo ''
\echo '── the policies, and what is a plan rather than a control'
SELECT environment, in_effect, retention_days, rpo_minutes, rto_minutes FROM backup_policies;

\echo ''
\echo '── the register answers the questions it is for'

SELECT expect('every environment has a stated backup policy, including the one whose answer is none',
  (SELECT count(*) = 0 FROM backup_gaps));

SELECT expect('no policy is in effect without somebody having restored from it',
  (SELECT count(*) = 0 FROM in_effect_without_drill));

SELECT expect('no passed drill took longer than the target it was measured against',
  (SELECT count(*) = 0 FROM rto_missed));

SELECT expect('no drill has gone stale',
  (SELECT count(*) = 0 FROM drill_overdue));

SELECT expect('and the environments nobody has drilled are shown as such rather than omitted',
  (SELECT count(*) > 0 FROM never_drilled));

SELECT expect('a drill has actually been run and recorded',
  (SELECT count(*) > 0 FROM restore_drills WHERE outcome = 'passed'));


-- ── the register can fail ──────────────────────────────────────────────────────

\echo ''
\echo '── proving those answers are not zero by construction'

SELECT expect_noticed('a policy is switched on before anyone has restored from it',
  $$UPDATE backup_policies SET in_effect = true WHERE environment = 'production'$$,
  'in_effect_without_drill');

SELECT expect_noticed('a drill takes four times the target and is recorded as passed',
  $$INSERT INTO restore_drills (performed_on, performed_by, environment, source_snapshot_at,
      restored_into, minutes_to_restore, rows_verified, copy_detected, scrub_confirmed, outcome)
    VALUES (current_date, 'probe', 'development', now(), 'probe', 5760, 1, true, true, 'passed')$$,
  'rto_missed');

SELECT expect_noticed('the last drill was a year ago',
  $$UPDATE restore_drills SET performed_on = current_date - 400$$,
  'drill_overdue');

SELECT expect_noticed('an environment loses its policy',
  $$DELETE FROM backup_policies WHERE environment = 'staging'$$,
  'backup_gaps');

SELECT expect_rejected('a drill that passed without the copy refusing to serve', $$
  INSERT INTO restore_drills (performed_on, performed_by, environment, source_snapshot_at,
    restored_into, minutes_to_restore, rows_verified, copy_detected, scrub_confirmed, outcome)
  VALUES (current_date, 'probe', 'development', now(), 'probe', 5, 1, false, true, 'passed')
$$);

SELECT expect_rejected('a drill that passed without the copy being scrubbed', $$
  INSERT INTO restore_drills (performed_on, performed_by, environment, source_snapshot_at,
    restored_into, minutes_to_restore, rows_verified, copy_detected, scrub_confirmed, outcome)
  VALUES (current_date, 'probe', 'development', now(), 'probe', 5, 1, true, false, 'passed')
$$);

SELECT expect_rejected('a retention window of zero days', $$
  UPDATE backup_policies SET retention_days = 0 WHERE environment = 'production'
$$);


-- ── the gate ───────────────────────────────────────────────────────────────────
--
-- The positive control first. A zero further down means nothing unless the same query
-- returns something here.

\echo ''
\echo '── what the application reads where the database was written'

SELECT expect('the database knows it is the original',
  deployment_is_original() AND app_data_is_servable());

SET ROLE dailycare_app;
SELECT set_config('app.user_id', 'a0000000-0000-0000-0000-00000000000a', false) \gset
SELECT expect('a care manager reads the resident and the care note',
  (SELECT count(*) = 1 FROM residents) AND (SELECT count(*) = 1 FROM care_days));
RESET ROLE;

\echo ''
\echo '── and now the same database, restored somewhere else'
-- What a restore does to this row: it arrives still naming the database it was written in.
\set QUIET on
UPDATE deployment SET database_name = 'dailycare_production';
\set QUIET off

SELECT expect('it works out that it is a copy',
  NOT deployment_is_original());

SELECT expect('and stops being servable',
  NOT app_data_is_servable());

SET ROLE dailycare_app;
SELECT set_config('app.user_id', 'a0000000-0000-0000-0000-00000000000a', false) \gset
SELECT expect('the same care manager now reads nothing at all',
  (SELECT count(*) = 0 FROM residents) AND (SELECT count(*) = 0 FROM care_days));
RESET ROLE;

SELECT expect('though the record is still physically there, which is what the gate is for',
  (SELECT count(*) = 1 FROM care_days WHERE note LIKE '%frightened%'));

\set QUIET on
UPDATE deployment SET environment = 'development', label = 'restored copy';
\set QUIET off
\set QUIET on
UPDATE deployment SET database_name = current_database(), cluster_id = 'another-instance';
\set QUIET off
SELECT expect('a move to another instance closes it too, not only a rename',
  NOT deployment_is_original() AND NOT app_data_is_servable());


-- ── a production recovery must not be blocked ──────────────────────────────────
--
-- Deliberately before the scrub below. A database that has been scrubbed under its own
-- name is clear whatever its deployment row later claims about where it came from, which
-- is correct - the scrub happened here - and would make this scenario untestable if the
-- two ran the other way round.

\echo ''
\echo '── a production snapshot brought up on new hardware'
\set QUIET on
UPDATE deployment SET environment = 'production', database_name = 'dailycare_production',
                      cluster_id = 'the-instance-that-failed';
\set QUIET off

SELECT expect('it refuses to serve until somebody says it is the database now',
  NOT app_data_is_servable());

SELECT expect_rejected('claiming a database by the wrong name', $$
  SELECT claim_this_database('some-other-database', 'production', 'no')
$$);

\set QUIET on
SELECT claim_this_database(current_database(), 'production', 'recovery from snapshot');
\set QUIET off

SELECT expect('one deliberate statement brings it back',
  app_data_is_servable() AND deployment_is_original());

SELECT expect('and the row says what was decided and why',
  (SELECT label = 'recovery from snapshot' AND environment = 'production' FROM deployment));

SET ROLE dailycare_app;
SELECT set_config('app.user_id', 'a0000000-0000-0000-0000-00000000000a', false) \gset
SELECT expect('and the records are there, because a recovery that scrubbed them would be a loss',
  (SELECT count(*) = 1 FROM care_days WHERE note LIKE '%frightened%'));
RESET ROLE;


-- ── the other way a copy is reopened ───────────────────────────────────────────

\echo ''
\echo '── a copy taken for development instead'
\set QUIET on
UPDATE deployment SET database_name = 'dailycare_production',
                      cluster_id = 'the-production-instance';
\set QUIET off

SELECT expect('closed again, as any copy is',
  NOT app_data_is_servable());

\set QUIET on
UPDATE deployment SET environment = 'development', label = 'restored copy';
\set QUIET off

SELECT expect('relabelling it development is not enough on its own',
  NOT app_data_is_servable());

\set QUIET on
SELECT checks_end();
SELECT scrub_phi(current_database());
SELECT checks_begin();
\set QUIET off

SELECT expect('the scrub reopened the gate and took ownership of the database',
  app_data_is_servable() AND deployment_is_original());

SELECT expect('and stamped when it happened',
  (SELECT phi_scrubbed_at IS NOT NULL FROM deployment));

SET ROLE dailycare_app;
SELECT set_config('app.user_id', 'a0000000-0000-0000-0000-00000000000a', false) \gset
SELECT expect('the application has a working database again',
  (SELECT count(*) = 1 FROM care_days));
RESET ROLE;

SELECT expect('and it is no longer the record it was',
  (SELECT count(*) = 0 FROM care_days WHERE note LIKE '%frightened%'));


-- ── the unlabelled case, which is documented rather than enforced ──────────────

\echo ''
\echo '── a database that has never said what it is'
\set QUIET on
CREATE TEMP TABLE saved_deployment AS SELECT * FROM deployment;
DELETE FROM deployment;
\set QUIET off

SELECT expect('serves, deliberately: it has never claimed to be anything to be copied from',
  app_data_is_servable());

\set QUIET on
INSERT INTO deployment SELECT * FROM saved_deployment;
\set QUIET off


-- ── who may read the register ──────────────────────────────────────────────────

\echo ''
\echo '── the register is not application data'
SET ROLE dailycare_app;
SELECT expect_rejected('the application reading the backup policies', $$
  SELECT count(*) FROM backup_policies
$$);
SELECT expect_rejected('the application recording a drill it did not run', $$
  INSERT INTO restore_drills (performed_on, performed_by, environment, source_snapshot_at,
    restored_into, minutes_to_restore, rows_verified, copy_detected, scrub_confirmed, outcome)
  VALUES (current_date, 'app', 'production', now(), 'x', 1, 1, true, true, 'passed')
$$);
RESET ROLE;

\echo ''
\echo '── drills on record'
SELECT performed_on, environment, restored_into, minutes_to_restore,
       copy_detected, scrub_confirmed, outcome FROM restore_drills ORDER BY id;

\set QUIET on
SELECT checks_end();
DROP FUNCTION expect(text, boolean);
DROP FUNCTION expect_rejected(text, text);
DROP FUNCTION expect_noticed(text, text, text);
\set QUIET off
