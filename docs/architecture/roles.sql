-- Roles
--
-- Applied first, before schema.sql.
--
-- Three roles, and none of them is the one you are connected as. The owner creates the
-- objects; these are what the running system uses, and every file after this one grants
-- to them rather than creating them, so the rest of the model can be applied by somebody
-- who is not allowed to create a role at all.
--
-- Needs a role that may create roles. On a managed instance the default administrator has
-- that; on a laptop the default user usually is a superuser. If neither is true, ask for
-- these three to be created once and then apply everything else as yourself.

DO $$
DECLARE
  wanted text[] := ARRAY['dailycare_app', 'dailycare_retention', 'dailycare_integration',
                         'dailycare_backup'];
  r      text;
  made   int := 0;
BEGIN
  FOREACH r IN ARRAY wanted LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      BEGIN
        EXECUTE format('CREATE ROLE %I NOLOGIN', r);
        made := made + 1;
      EXCEPTION WHEN insufficient_privilege THEN
        RAISE EXCEPTION
          'cannot create role %. Ask for these to be created once, then apply the rest as yourself: %',
          r, array_to_string(wanted, ', ')
          USING HINT = 'CREATE ROLE <name> NOLOGIN; -- for each of them';
      END;
    END IF;
  END LOOP;
  -- The person applying this has to be able to become these roles, because that is how
  -- every check in this directory tests a policy: it stops being the owner and asks the
  -- question as the application. Without the membership the checks cannot run at all, and
  -- a suite that cannot run is not a suite that passed.
  FOREACH r IN ARRAY wanted LOOP
    IF NOT pg_has_role(current_user, r, 'MEMBER') THEN
      BEGIN
        EXECUTE format('GRANT %I TO %I', r, current_user);
      EXCEPTION WHEN insufficient_privilege THEN
        RAISE EXCEPTION 'cannot grant % to %', r, current_user
          USING HINT = 'Ask for: GRANT <role> TO <your user>; -- for each of the three';
      END;
    END IF;
  END LOOP;

  -- The role that owns the schema and everything in it.
  --
  -- None of the four above owns anything - app_owns_something is the check that says so -
  -- and until this existed the owner was whoever applied the model. On a managed instance
  -- that is the built-in administrator, which meant its password had to exist somewhere
  -- for every migration, and every job that ran one held it.
  --
  -- NOLOGIN, and deliberately no CREATEROLE. On PostgreSQL 14 a CREATEROLE role may alter
  -- any non-superuser role including setting its password, so giving it here would make
  -- the migration identity a route to every other identity in the cluster.
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dailycare_owner') THEN
    BEGIN
      CREATE ROLE dailycare_owner NOLOGIN;
    EXCEPTION WHEN insufficient_privilege THEN
      RAISE EXCEPTION 'cannot create dailycare_owner'
        USING HINT = 'CREATE ROLE dailycare_owner NOLOGIN;';
    END;
  END IF;

  -- WITH ADMIN OPTION so the owner can run cloudsql-iam.sql, which grants each application
  -- role to the Cloud SQL IAM user that connects as it. Without it that file needs the
  -- instance administrator every time a service account is added.
  FOREACH r IN ARRAY wanted LOOP
    EXECUTE format('GRANT %I TO dailycare_owner WITH ADMIN OPTION', r);
  END LOOP;

  -- So a container run, where the applying role is not dailycare_owner, still produces a
  -- database shaped like the deployed one. A notice rather than an exception: a cluster
  -- where this cannot be granted still gets a working suite, and schema-privileges.sql
  -- says what it could not do.
  IF NOT pg_has_role(current_user, 'dailycare_owner', 'MEMBER') THEN
    BEGIN
      EXECUTE format('GRANT dailycare_owner TO %I', current_user);
    EXCEPTION WHEN insufficient_privilege THEN
      RAISE NOTICE 'dailycare_owner exists but could not be granted to %', current_user;
    END;
  END IF;

  -- A logical export is the one operation FORCE ROW LEVEL SECURITY breaks. pg_dump run by
  -- the owner fails on every PHI table, and run with --enable-row-security it succeeds
  -- while quietly dumping only the rows the policies let it see, which is worse. So the
  -- export role bypasses row-level security, and nothing else does.
  --
  -- Only a superuser may grant that. On a managed instance where nobody is one, managed
  -- snapshots are the backup mechanism and a logical export needs the platform's own
  -- administrative role. Either way it is a deliberate grant rather than an assumption.
  BEGIN
    EXECUTE 'ALTER ROLE dailycare_backup BYPASSRLS';
    RAISE NOTICE 'dailycare_backup may bypass row-level security, so pg_dump can see every row';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'dailycare_backup exists but cannot be given BYPASSRLS from this connection. Logical exports need a role that has it; managed snapshots do not.';
  END;

  RAISE NOTICE 'roles: % created, % already present, all granted to %',
    made, array_length(wanted,1) - made, current_user;
END $$;

-- What each of them is for. Left as comments rather than COMMENT ON ROLE, because a role
-- is a cluster-wide object and commenting on one needs the same privilege as creating one -
-- which is the privilege this file is trying not to require twice.
--
--   dailycare_app          What the API connects as. Not an owner, so row-level security
--                          applies to it.
--   dailycare_retention    The scheduled deletion job. May remove expired records and may
--                          not read a care note.
--   dailycare_integration  Writes medication events attributed to a clinical system.
--                          Nothing a request can reach.
--   dailycare_backup       Takes logical exports. The only role that bypasses row-level
--                          security, because a dump that respects it is a partial dump
--                          that looks complete.
