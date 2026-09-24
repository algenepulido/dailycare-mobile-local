#!/usr/bin/env bash
#
# Handing the schema to dailycare_owner. Once per instance, as postgres.
#
# The only ownership statement that is not in the model, and it is here rather than there
# for a reason: a model file that needed to own the schema would refuse to apply on every
# database where it did not, which is every database until somebody had already done this.
#
# ORDER. Run this only once the jobs already connect as the migration login. DROP SCHEMA
# needs the schema's owner, so after this the reset job - which is that login, defaulting
# to dailycare_owner - drops the postgres-owned tables along with the schema and rebuilds
# everything owned correctly. Run it the other way round and the next reset puts every
# table back on postgres, which is what happened on this instance on 23 September between
# 21:45 and 22:08.
#
# The object-by-object catch-up is here too, and it was nearly left out.
#
# On dev the reset does it: it drops the schema and rebuilds everything as the migration
# login, so moving the schema was enough. But reset refuses to run outside dev - correctly,
# and by instruction - so staging and production have no such loop. Without this they come
# up with a schema owned by dailycare_owner, every object owned by postgres, and a
# migration identity that cannot read its own tables. Which is exactly what staging did.
#
# So: "the reset renews it" is true where there is a reset, and the environments that
# cannot be reset are the ones that needed this most. Taken from the review's bootstrap.sql,
# which had it right.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/connect.sh"

echo "── before"
psql -c "SELECT pg_get_userbyid(nspowner) AS schema_owner FROM pg_namespace WHERE nspname='public'"
psql -c "SELECT pg_get_userbyid(relowner) AS owner, count(*) AS objects
         FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
         WHERE n.nspname='public' AND c.relkind IN ('r','v','S') GROUP BY 1 ORDER BY 2 DESC"

# postgres has to be a member of the role it hands an object to. Left in place afterwards:
# postgres is cloudsqlsuperuser and can grant itself back in one statement, so removing it
# would buy nothing and a break-glass session would have no way to fix a mistake here.
psql -v ON_ERROR_STOP=1 -c "GRANT dailycare_owner TO postgres"

# CREATE on the database, so the owner can recreate the schema a reset drops.
psql -v ON_ERROR_STOP=1 -c "GRANT CREATE ON DATABASE ${DB_NAME} TO dailycare_owner"
psql -v ON_ERROR_STOP=1 -c "ALTER SCHEMA public OWNER TO dailycare_owner"

# Three blocks rather than one, so a refusal in one kind of object leaves the others moved.
# Every ALTER is idempotent on a re-run: each selects only what postgres still owns.
psql -v ON_ERROR_STOP=1 <<'SQL'
DO $$
DECLARE r record; moved int := 0;
BEGIN
  FOR r IN
    SELECT c.relname, c.relkind
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_roles o     ON o.oid = c.relowner
    WHERE n.nspname = 'public' AND o.rolname = 'postgres'
      AND c.relkind IN ('r','p','v','m','S','f')
      -- A sequence owned through its table follows it, and ALTER SEQUENCE OWNER on one is
      -- refused. Only a free-standing sequence is moved here.
      AND NOT (c.relkind = 'S' AND EXISTS (
        SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_class'::regclass
          AND d.objid = c.oid AND d.deptype IN ('a','i')))
      -- Objects an extension installed belong to the extension. citext and pgcrypto put
      -- functions and a type in public and changing their owner is refused.
      AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_class'::regclass
                        AND d.objid = c.oid AND d.deptype = 'e')
    ORDER BY (c.relkind IN ('r','p')) DESC, c.relname
  LOOP
    EXECUTE format(CASE r.relkind
      WHEN 'v' THEN 'ALTER VIEW %I OWNER TO dailycare_owner'
      WHEN 'm' THEN 'ALTER MATERIALIZED VIEW %I OWNER TO dailycare_owner'
      WHEN 'S' THEN 'ALTER SEQUENCE %I OWNER TO dailycare_owner'
      WHEN 'f' THEN 'ALTER FOREIGN TABLE %I OWNER TO dailycare_owner'
      ELSE          'ALTER TABLE %I OWNER TO dailycare_owner' END, r.relname);
    moved := moved + 1;
  END LOOP;
  RAISE NOTICE 'tables, views and sequences moved: %', moved;
END $$;

-- ALTER ROUTINE rather than ALTER FUNCTION: the model has procedures too, and ALTER
-- FUNCTION refuses one. The SECURITY DEFINER functions keep behaving identically, because
-- the role they now run as owns the same tables the old one did.
DO $$
DECLARE r record; moved int := 0;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS signature
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    JOIN pg_roles o     ON o.oid = p.proowner
    WHERE n.nspname = 'public' AND o.rolname = 'postgres'
      AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_proc'::regclass
                        AND d.objid = p.oid AND d.deptype = 'e')
  LOOP
    EXECUTE format('ALTER ROUTINE %s OWNER TO dailycare_owner', r.signature);
    moved := moved + 1;
  END LOOP;
  RAISE NOTICE 'functions and procedures moved: %', moved;
END $$;

DO $$
DECLARE r record; moved int := 0;
BEGIN
  FOR r IN
    SELECT t.typname
    FROM pg_type t
    JOIN pg_namespace n ON n.oid = t.typnamespace
    JOIN pg_roles o     ON o.oid = t.typowner
    WHERE n.nspname = 'public' AND o.rolname = 'postgres' AND t.typtype IN ('e','d')
      AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_type'::regclass
                        AND d.objid = t.oid AND d.deptype = 'e')
  LOOP
    EXECUTE format('ALTER TYPE %I OWNER TO dailycare_owner', r.typname);
    moved := moved + 1;
  END LOOP;
  RAISE NOTICE 'enums and domains moved: %', moved;
END $$;
SQL

echo "── after"
psql -c "SELECT pg_get_userbyid(nspowner) AS schema_owner FROM pg_namespace WHERE nspname='public'"
psql -c "SELECT pg_get_userbyid(relowner) AS owner, count(*) AS objects
         FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
         WHERE n.nspname='public' AND c.relkind IN ('r','v','S') GROUP BY 1 ORDER BY 2 DESC"
echo ""
echo "Anything still on postgres above belongs to an extension, which is where it stays."
