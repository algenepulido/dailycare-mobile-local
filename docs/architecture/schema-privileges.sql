-- What PUBLIC may do in the schema
--
-- Last in model.list, after every table and every grant, because it takes away a
-- privilege that everything before it has been relying on having.
--
-- PostgreSQL 14 grants CREATE on schema public to PUBLIC at initdb. Every role in the
-- cluster can therefore create objects in the schema the application reads - including
-- dailycare_app. Nobody granted that, it is in no access matrix, and a table created
-- there by the application is a place to put rows outside every policy, every column
-- grant and every audit trigger in this directory. PostgreSQL 15 changed the default;
-- this model runs on 14.
--
-- Confirmed rather than read: as dailycare_app, on a database built from this model,
-- CREATE TABLE in public was accepted and the table came back owned by dailycare_app.
--
-- It is not a narrowing of anybody's access. Nothing in the model has ever created an
-- object as an application role, and app_owns_something asserts that none of them owns
-- one.
--
-- A schema that a reset recreated does not have the grant - the default belongs to the
-- initdb public schema and not to CREATE SCHEMA, checked the same way - so a reset
-- database and a fresh one disagreed about this until the statement below existed. That
-- is the reason it is in the model rather than a thing done once per instance: the
-- fourteen suite databases, the API's test container, dev and staging all get the same
-- answer.

-- Guarded, because only the schema's owner may revoke on it and who that is depends on
-- how the database was made. A deployed instance is owned by dailycare_owner and a reset
-- renews that; a suite database is owned by whoever ran createdb, which review.sh arranges
-- by preparing template1 once. Somebody running verify.sh against their own PostgreSQL may
-- be neither, and a model file is the wrong place to refuse them a database - so it says
-- exactly what to run and schema_privilege_drift reports the gap rather than hiding it.
DO $$
BEGIN
  EXECUTE 'REVOKE CREATE ON SCHEMA public FROM PUBLIC';
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'cannot revoke CREATE on schema public: this role does not own it'
    USING HINT = 'As an administrator, once per cluster: ALTER SCHEMA public OWNER TO dailycare_owner; or on template1 before creating suite databases.';
END $$;

-- Which leaves USAGE, stated rather than left to the default, because the revoke above is
-- close enough to it that the next reader should not have to work out that they differ.
GRANT USAGE ON SCHEMA public
  TO dailycare_app, dailycare_retention, dailycare_integration, dailycare_backup;

COMMENT ON SCHEMA public IS
  'CREATE is revoked from PUBLIC. A role that may create here may create a table outside
   the policies, the grants and the audit triggers, which is a way around all three at
   once. Owned by dailycare_owner on a deployed instance, and by whoever applied the model
   in a suite database.';


-- The state, as data, so it can be compared against rather than assumed.
CREATE VIEW schema_privilege_drift AS
SELECT n.nspname AS schema,
       coalesce((SELECT bool_or(a.privilege_type = 'CREATE')
                 FROM aclexplode(n.nspacl) a WHERE a.grantee = 0), false) AS public_may_create
FROM pg_namespace n
WHERE n.nspname = 'public'
  AND coalesce((SELECT bool_or(a.privilege_type = 'CREATE')
                FROM aclexplode(n.nspacl) a WHERE a.grantee = 0), false);

COMMENT ON VIEW schema_privilege_drift IS
  'Must be empty. One row means PUBLIC may create in the schema the application reads,
   which is every role in the cluster being able to put a table where no policy, grant or
   trigger in this directory applies.';
