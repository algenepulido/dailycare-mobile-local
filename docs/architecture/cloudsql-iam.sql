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

    EXECUTE format('GRANT %I TO %I', pairs[i][2], iam_user);

    -- Inherited rather than assumed with SET ROLE. A connection that has to remember to
    -- become somebody is a connection that will one day forget, and the forgetting looks
    -- like a policy refusing a caregiver rather than like a bug.
    EXECUTE format('ALTER ROLE %I INHERIT', iam_user);

    RAISE NOTICE 'granted % to %', pairs[i][2], iam_user;
  END LOOP;
END $$;
