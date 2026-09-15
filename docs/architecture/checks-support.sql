-- Support for the invariant files
--
-- Applied after the model, before any *-invariants.sql. Not part of the production model.
--
-- Every PHI table forces row-level security, which means the owner is subject to it too -
-- that is the whole point of FORCE rather than ENABLE. It also means the checks behave
-- differently depending on who runs them, and that difference is a trap:
--
--   A superuser bypasses row-level security entirely, so the checks seed their fixtures
--   and read their results without noticing the policies at all.
--
--   A non-superuser owner - which is what a managed instance gives you, and therefore what
--   production actually is - does not. Fixtures fail to insert, and, far worse, the reads
--   that verify a deletion return zero rows because the policy hid them rather than
--   because the row is gone. That is a check passing for the wrong reason.
--
-- So each suite lifts FORCE for itself and puts it back at the end. The policies are still
-- there and still enforced; what changes is that the owner reads the tables as an owner.
-- Nothing under test is weakened, because every check that tests a policy does it by
-- becoming dailycare_app or dailycare_retention and asking as them.

CREATE TABLE IF NOT EXISTS checks_forced_tables (table_name text PRIMARY KEY);

CREATE OR REPLACE FUNCTION checks_begin() RETURNS void
LANGUAGE plpgsql
  SET search_path = pg_catalog, public AS $$
DECLARE r record;
BEGIN
  DELETE FROM checks_forced_tables;
  FOR r IN SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname = 'public' AND c.relrowsecurity AND c.relforcerowsecurity
  LOOP
    INSERT INTO checks_forced_tables VALUES (r.relname);
    EXECUTE format('ALTER TABLE %I NO FORCE ROW LEVEL SECURITY', r.relname);
  END LOOP;
END; $$;

CREATE OR REPLACE FUNCTION checks_end() RETURNS void
LANGUAGE plpgsql
  SET search_path = pg_catalog, public AS $$
DECLARE r record;
BEGIN
  FOR r IN SELECT table_name FROM checks_forced_tables LOOP
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', r.table_name);
  END LOOP;
  DELETE FROM checks_forced_tables;
END; $$;

COMMENT ON FUNCTION checks_begin() IS
  'Called at the top of each invariant file so that a suite run by a non-superuser gives
   the same answers as one run by a superuser. If it did not, the suite would report
   success on a managed instance while testing almost nothing.';
