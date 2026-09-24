-- Connecting Cloud SQL's IAM users to this model's roles.
--
-- Not part of model.list, and deliberately. Every file there describes the database and
-- applies anywhere PostgreSQL runs; this one names four Google service accounts and only
-- means anything on a Cloud SQL instance with cloudsql.iam_authentication on. A container
-- has no such users and applying it there would fail.
--
--   psql -f cloudsql-iam.sql -v project=inktree-dailycare-dev -v env=dev
--
-- Run once per instance, by whoever can grant roles.
--
-- What it does and why it is not just a convenience: with it, nothing holds a database
-- password. The API proves who it is with the identity the revision runs as, Cloud SQL
-- maps that to a database user, and this hands that user the role the model already
-- describes. A password would be a fifth thing to store, rotate and eventually leak, and
-- the whole point of iam.disableServiceAccountKeyCreation upstream is that there is
-- nothing of that shape anywhere.
--
-- The mapping is one to one and the names are not a coincidence: dc-dev-api runs as
-- dailycare_app, and neither is allowed to be the other's. Four accounts because they do
-- four different things, and a compromise of one is a compromise of one.

\set ON_ERROR_STOP on

DO $$
DECLARE
  project text := current_setting('dailycare.project', true);
  env     text := current_setting('dailycare.env', true);
  pairs   text[][] := ARRAY[
    ['api',         'dailycare_app'],
    ['retention',   'dailycare_retention'],
    ['integration', 'dailycare_integration'],
    ['backup',      'dailycare_backup']
  ];
  iam_user text;
  i int;
BEGIN
  IF project IS NULL OR env IS NULL THEN
    RAISE EXCEPTION 'set dailycare.project and dailycare.env first'
      USING HINT = 'psql -c "SET dailycare.project = ...; SET dailycare.env = ..."';
  END IF;

  FOR i IN 1 .. array_length(pairs, 1) LOOP
    iam_user := format('dc-%s-%s@%s.iam', env, pairs[i][1], project);

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = iam_user) THEN
      -- The user is created by Cloud SQL when the service account is added as a database
      -- user, not by this file. Saying which one is missing is more use than a failure
      -- naming a role nobody has heard of.
      RAISE EXCEPTION 'no database user %. Add the service account to the instance first.', iam_user;
    END IF;

    IF NOT pg_has_role(iam_user, pairs[i][2], 'MEMBER') THEN
      EXECUTE format('GRANT %I TO %I', pairs[i][2], iam_user);
      RAISE NOTICE 'granted % to %', pairs[i][2], iam_user;
    END IF;

    -- Inherited rather than assumed with SET ROLE. A connection that has to remember to
    -- become somebody is a connection that will one day forget, and the forgetting looks
    -- like a policy refusing a caregiver rather than like a bug.
    --
    -- Guarded, because ALTER ROLE needs CREATEROLE and the migration login does not have
    -- it - deliberately: on PostgreSQL 14 a CREATEROLE role may set any non-superuser
    -- role's password, which would make this identity a route to every other one. So on a
    -- second run, by the login rather than by the administrator, this has to not execute
    -- rather than fail. It ran unguarded and took a whole reset down with it after the
    -- model had already applied.
    IF NOT (SELECT rolinherit FROM pg_roles WHERE rolname = iam_user) THEN
      EXECUTE format('ALTER ROLE %I INHERIT', iam_user);
      RAISE NOTICE '% now inherits', iam_user;
    END IF;
  END LOOP;
END $$;


-- The migration identity.
--
-- Separate from the loop above because it is not one of the four the running system
-- connects as. Those four read and write rows under the policies; this one owns the
-- schema and is the only thing that changes it, and the whole reason it exists is that
-- those two jobs were the same account holding the same superuser password.
DO $$
DECLARE
  project text := current_setting('dailycare.project', true);
  env     text := current_setting('dailycare.env', true);
  u       text;
BEGIN
  IF project IS NULL OR env IS NULL THEN
    RAISE EXCEPTION 'set dailycare.project and dailycare.env first';
  END IF;
  u := format('dc-%s-migrate@%s.iam', env, project);

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = u) THEN
    RAISE EXCEPTION 'no database user %. Add the service account to the instance first.', u;
  END IF;

  IF NOT pg_has_role(u, 'dailycare_owner', 'MEMBER') THEN
    EXECUTE format('GRANT dailycare_owner TO %I', u);
    RAISE NOTICE 'granted dailycare_owner to %', u;
  END IF;

  -- Every session starts as the owner, so whatever a migration or a reset creates belongs
  -- to the role rather than to the login. This is the line that makes a reset renew the
  -- ownership instead of undoing it - without it, the first reset after an ownership
  -- handover puts every table back on whoever ran it, which is what happened on this
  -- instance on 23 September, twenty minutes after the handover.
  IF NOT EXISTS (
    SELECT 1 FROM pg_db_role_setting s JOIN pg_roles r ON r.oid = s.setrole
    WHERE r.rolname = u AND 'role=dailycare_owner' = ANY (s.setconfig)) THEN
    EXECUTE format('ALTER ROLE %I SET role = ''dailycare_owner''', u);
    RAISE NOTICE '% now starts every session as dailycare_owner', u;
  END IF;

  -- verify.sh builds a database per suite. CREATEDB is not inherited through membership
  -- and is checked against the current role, which after the line above is the owner.
  IF NOT (SELECT rolcreatedb FROM pg_roles WHERE rolname = 'dailycare_owner') THEN
    ALTER ROLE dailycare_owner CREATEDB;
    RAISE NOTICE 'dailycare_owner may create databases';
  END IF;
END $$;
