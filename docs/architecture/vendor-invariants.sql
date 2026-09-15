-- Vendor register checks for vendors.sql
--
--   createdb dc_vendor_check
--   psql -v ON_ERROR_STOP=1 -d dc_vendor_check -f schema.sql
--   psql -v ON_ERROR_STOP=1 -d dc_vendor_check -f access-policies.sql
--   psql -v ON_ERROR_STOP=1 -d dc_vendor_check -f data-classification.sql
--   psql -v ON_ERROR_STOP=1 -d dc_vendor_check -f audit-logging.sql
--   psql -v ON_ERROR_STOP=1 -d dc_vendor_check -f retention.sql
--   psql -v ON_ERROR_STOP=1 -d dc_vendor_check -f environments.sql
--   psql -v ON_ERROR_STOP=1 -d dc_vendor_check -f vendors.sql
--   psql -d dc_vendor_check -f vendor-invariants.sql
--   dropdb dc_vendor_check
--
-- A register of third parties is a list, and a list passes any check that only asks
-- whether it is non-empty. So half of what follows is the other direction: a vendor is
-- deliberately moved into each bad state in turn, the view is asked whether it noticed,
-- and the change is rolled back. A view that has only ever returned zero has not been
-- shown to be capable of returning anything.

\set QUIET on
SET client_min_messages TO notice;

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

-- Puts the register into a state it should not be in, asks the view, and puts it back.
CREATE OR REPLACE FUNCTION expect_noticed(label text, break text, view_name text)
RETURNS void AS $$
DECLARE before_n bigint; after_n bigint;
BEGIN
  EXECUTE format('SELECT count(*) FROM %I', view_name) INTO before_n;
  BEGIN
    EXECUTE break;
    EXECUTE format('SELECT count(*) FROM %I', view_name) INTO after_n;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'PASS  refused outright (%): %', SQLERRM, label;
    RETURN;
  END;
  IF after_n > before_n THEN RAISE NOTICE 'PASS  % noticed: %', view_name, label;
  ELSE RAISE NOTICE 'FAIL  % did not notice: %', view_name, label;
  END IF;
  RAISE EXCEPTION 'rollback_probe';
EXCEPTION WHEN OTHERS THEN
  IF SQLERRM <> 'rollback_probe' THEN RAISE; END IF;
END; $$ LANGUAGE plpgsql;
\set QUIET off


-- ── the register as it stands ──────────────────────────────────────────────────

\echo ''
\echo '── who touches a resident record'
SELECT id, role, live, baa, exposure FROM phi_vendors;

\echo ''
\echo '── and what is still open'
SELECT id, baa, gap_owner, gap_required_before FROM vendor_gaps;

\echo ''
\echo '── the register is answering a real question'

SELECT expect('somebody is recorded as holding a resident record',
  (SELECT count(*) > 0 FROM phi_vendors));

SELECT expect('and the register is not one line long, which would make every check below cheap',
  (SELECT count(*) >= 6 FROM vendors));

SELECT expect('every vendor has been asked about PHI, including the ones the answer is no for',
  (SELECT count(*) = 0 FROM vendors_without_phi_answer));

SELECT expect('and "no" is genuinely recorded rather than left out',
  (SELECT count(*) > 0 FROM vendor_exposure WHERE class = 'phi' AND exposure = 'none'));

SELECT expect('no vendor review is older than a year',
  (SELECT count(*) = 0 FROM stale_reviews));


-- ── the three that must be empty ───────────────────────────────────────────────

\echo ''
\echo '── the answers that have to be zero'

SELECT expect('nobody is carrying a live record without an agreement',
  (SELECT count(*) = 0 FROM live_without_agreement));

SELECT expect('every open gap has an owner, a date and a stated reason',
  (SELECT count(*) = 0 FROM unacknowledged_gaps));

SELECT expect('everything that could receive PHI by accident names what stops it',
  (SELECT count(*) = 0 FROM uncontrolled_exposure));

\echo ''
\echo '── gaps that are open, acknowledged, and expected to be'
SELECT expect('there are open gaps, and hiding them would be the actual failure',
  (SELECT count(*) > 0 FROM vendor_gaps));


-- ── and now the other direction ────────────────────────────────────────────────
--
-- Each of these breaks the register on purpose and asks whether anything noticed.

\echo ''
\echo '── proving the checks above can fail'

SELECT expect_noticed('a vendor with an unsigned agreement is switched on',
  $$UPDATE vendors SET live = true WHERE id = 'gcp'$$,
  'live_without_agreement');

SELECT expect_noticed('an open gap loses its owner',
  $$UPDATE vendors SET gap_owner = NULL WHERE id = 'gcp'$$,
  'unacknowledged_gaps');

SELECT expect_noticed('an open gap loses its date',
  $$UPDATE vendors SET gap_required_before = NULL WHERE id = 'twilio'$$,
  'unacknowledged_gaps');

SELECT expect_noticed('a new vendor is added and nobody says anything about PHI',
  $$INSERT INTO vendors (id, name, purpose, role, baa, reviewed_on)
    VALUES ('probe', 'Probe', 'Added by a check', 'processor', 'not_required', current_date)$$,
  'vendors_without_phi_answer');

SELECT expect_noticed('a review is left untouched for two years',
  $$UPDATE vendors SET reviewed_on = current_date - 800 WHERE id = 'stripe'$$,
  'stale_reviews');

SELECT expect_rejected('recording an accidental exposure without naming a control', $$
  INSERT INTO vendor_exposure (vendor_id, class, exposure)
  VALUES ('stripe', 'secret', 'could_receive')
$$);

SELECT expect_rejected('claiming an agreement is signed without saying when', $$
  INSERT INTO vendors (id, name, purpose, role, baa, reviewed_on)
  VALUES ('probe2', 'Probe', 'Added by a check', 'processor', 'signed', current_date)
$$);

SELECT expect_rejected('an exposure row for a vendor that is not in the register', $$
  INSERT INTO vendor_exposure (vendor_id, class, exposure)
  VALUES ('nonexistent', 'phi', 'none')
$$);

SELECT expect_rejected('two exposure rows for the same vendor and class', $$
  INSERT INTO vendor_exposure (vendor_id, class, exposure)
  VALUES ('stripe', 'phi', 'holds')
$$);


-- ── the register survived being probed ─────────────────────────────────────────

\echo ''
\echo '── and the register is as it was'

SELECT expect('the probes left nothing behind',
  (SELECT count(*) = 0 FROM vendors WHERE id LIKE 'probe%'));

SELECT expect('the three answers are zero again',
  (SELECT count(*) = 0 FROM live_without_agreement)
  AND (SELECT count(*) = 0 FROM unacknowledged_gaps)
  AND (SELECT count(*) = 0 FROM uncontrolled_exposure));

SELECT expect('and nothing became live while the checks were running',
  (SELECT count(*) = 2 FROM vendors WHERE live));


-- ── who may read it ────────────────────────────────────────────────────────────

\echo ''
\echo '── the register is not application data'

\set QUIET on
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dailycare_app') THEN
    CREATE ROLE dailycare_app NOLOGIN;
  END IF;
END $$;
GRANT USAGE ON SCHEMA public TO dailycare_app;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO dailycare_app;
REVOKE ALL ON vendors, vendor_exposure FROM dailycare_app;
\set QUIET off

SET ROLE dailycare_app;
SELECT expect_rejected('the application reading the vendor register', $$
  SELECT count(*) FROM vendors
$$);
SELECT expect_rejected('the application marking a vendor as agreed', $$
  UPDATE vendors SET baa = 'signed', baa_signed_on = current_date WHERE id = 'gcp'
$$);
RESET ROLE;

\echo ''
\echo '── exposure, in full'
SELECT ve.vendor_id, ve.class, ve.exposure,
       CASE WHEN ve.control IS NULL THEN '' ELSE 'controlled' END AS control
FROM vendor_exposure ve ORDER BY ve.vendor_id, ve.class;

\set QUIET on
DROP FUNCTION expect(text, boolean);
DROP FUNCTION expect_rejected(text, text);
DROP FUNCTION expect_noticed(text, text, text);
\set QUIET off
