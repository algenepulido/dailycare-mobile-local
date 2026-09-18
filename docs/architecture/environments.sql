-- Environments, and how a developer gets a realistic database
--
-- Applied after retention.sql.
--
-- "Development and test never hold PHI" is the easiest sentence in a compliance package
-- to write and the hardest to keep. It survives the first week. Then a bug only reproduces
-- on real data, somebody restores last night's backup into the staging project to look at
-- it, and the sentence has quietly become false in a way no document will notice.
--
-- So the sentence is not written here. What is written is the mechanism that makes it
-- true: a production snapshot is restored, scrubbed in place before anyone connects an
-- application to it, and then searched — every column of every table, not only the ones
-- believed to hold PHI — for anything the original contained.
--
-- Three properties matter more than the scrubbing itself.
--
-- The rules are a table, not code. Every column classified phi, identifying or secret
-- must have a rule, and unscrubbed_columns reports any that does not. A column added in a
-- later migration therefore arrives unscrubbed and fails a check, rather than being
-- silently carried into a developer's laptop.
--
-- "Keep" is a rule too. A mood, an appetite, a meal amount: once the name is gone and the
-- dates have moved, these are what make a dev database worth having, and each of them is
-- an explicit decision with a reason attached rather than an omission.
--
-- And the scan has to be shown to work. A completeness check that has only ever returned
-- zero has not been demonstrated to find anything, so the invariants plant a string in an
-- unclassified operational column and confirm the scanner reports it.


-- ════════════════════════════════════════════════════════════════════ which one is this

CREATE TYPE deployment_environment AS ENUM ('production', 'staging', 'development');

CREATE OR REPLACE FUNCTION deployment_cluster_id() RETURNS text
LANGUAGE sql STABLE
  SET search_path = pg_catalog, public AS $$ SELECT system_identifier::text FROM pg_control_system() $$;

CREATE TABLE deployment (
  only_row     boolean PRIMARY KEY DEFAULT true CHECK (only_row),
  environment  deployment_environment NOT NULL,
  label        text NOT NULL,

  -- Where this row was written. Both of these travel inside a backup, which is the point:
  -- a restore into another database or another instance arrives carrying the name and the
  -- cluster it came from, and no longer matches the one it is now running in. That is how
  -- a copy can know it is a copy without anybody remembering to tell it.
  database_name text NOT NULL DEFAULT current_database(),
  cluster_id    text NOT NULL DEFAULT deployment_cluster_id(),

  phi_scrubbed_at timestamptz,
  set_at       timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE deployment IS
  'One row, enforced by the primary key. A database that has not said which environment it
   is refuses to be scrubbed, because the safe assumption about an unlabelled database is
   that it is the live one.';


CREATE TABLE scrub_runs (
  id            bigserial PRIMARY KEY,
  ran_at        timestamptz NOT NULL DEFAULT now(),
  ran_by        text NOT NULL DEFAULT current_user,
  database_name text NOT NULL DEFAULT current_database(),
  environment   deployment_environment NOT NULL,
  shift_days    integer NOT NULL,
  columns_changed integer NOT NULL,
  rows_changed  bigint NOT NULL
);

COMMENT ON TABLE scrub_runs IS
  'A dev database can be asked when it was last scrubbed, and by whom. A snapshot that has
   been restored but not scrubbed has no row here, which is the question to ask it.';

-- ════════════════════════════════════════════════════════════════════ am I a copy
--
-- The dangerous moment in a backup strategy is not the backup. It is the twenty minutes
-- after a restore, when a production snapshot is sitting in a database called something
-- like dailycare_dev with somebody's laptop already pointed at it.
--
-- Asking an operator to scrub before connecting is a convention, and conventions are what
-- this whole directory exists to replace. So the database works it out. The deployment row
-- travels inside the dump; when it lands somewhere else, the name and the cluster it
-- records are no longer the ones it is running in, and until a scrub has been run under
-- this database's own name the application reads nothing at all.

CREATE OR REPLACE FUNCTION deployment_is_original() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = pg_catalog, public AS $$
  SELECT EXISTS (
    SELECT 1 FROM deployment d
    WHERE d.database_name = current_database()
      AND d.cluster_id    = deployment_cluster_id()
  )
$$;

CREATE OR REPLACE FUNCTION app_data_is_servable() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = pg_catalog, public AS $$
  SELECT CASE
    -- Never labelled. It has not claimed to be anything, so there is nothing to have been
    -- copied from; row-level security is still in force and is the protection here. Failing
    -- closed instead would brick a database whose deployment row was never written, and
    -- would buy nothing: anybody able to empty this table can already read the tables it
    -- is guarding.
    WHEN NOT EXISTS (SELECT 1 FROM deployment) THEN true
    WHEN deployment_is_original() THEN true
    -- A copy. Clear only once the scrub has run here, under this database's own name -
    -- the source's scrub history came along in the dump and does not count.
    --
    -- Read the other way round, this also says that a database scrubbed under its own name
    -- stays clear whatever its deployment row later claims about where it came from. That
    -- is right rather than a hole: the scrub happened in this database, so the records here
    -- have been through it, and the row is a statement about origin rather than contents.
    ELSE EXISTS (SELECT 1 FROM scrub_runs WHERE database_name = current_database())
  END
$$;

COMMENT ON FUNCTION app_data_is_servable() IS
  'False in a restored copy that has not been scrubbed. Read by app_user_id below, so the
   answer propagates to every policy in the access model at once rather than being
   remembered in each of them.';


-- A restore into a new instance is also how a real disaster recovery looks, and that one
-- must not be blocked. One deliberate statement, which belongs in the runbook and leaves
-- a record of itself.
-- The gate is wired in here rather than into each policy. app_user_id() already has the
-- property the access model is built on - null compares false everywhere, so a request that
-- cannot be identified reads nothing - and an unscrubbed copy should look exactly like a
-- request that cannot be identified.

CREATE OR REPLACE FUNCTION app_user_id() RETURNS uuid
LANGUAGE sql STABLE
  SET search_path = pg_catalog, public AS $$
  SELECT CASE WHEN app_data_is_servable()
              THEN nullif(current_setting('app.user_id', true), '')::uuid
              ELSE NULL END
$$;

COMMENT ON FUNCTION app_user_id() IS
  'Null when unset, and null compares false everywhere in the access model - so a request
   that forgets to identify itself reads nothing rather than everything. Null also in a
   restored copy that has not been scrubbed, for the same reason and with the same effect.';


CREATE OR REPLACE FUNCTION claim_this_database(
  confirm_database text,
  as_environment   deployment_environment,
  why              text
) RETURNS void LANGUAGE plpgsql
  SET search_path = pg_catalog, public AS $$
BEGIN
  IF confirm_database IS DISTINCT FROM current_database() THEN
    RAISE EXCEPTION 'refusing: called with %, connected to %',
      coalesce(confirm_database, '<null>'), current_database();
  END IF;
  UPDATE deployment SET environment   = as_environment,
                        label         = why,
                        database_name = current_database(),
                        cluster_id    = deployment_cluster_id(),
                        set_at        = now();
  IF NOT FOUND THEN
    INSERT INTO deployment (environment, label) VALUES (as_environment, why);
  END IF;
END; $$;

COMMENT ON FUNCTION claim_this_database(text, deployment_environment, text) IS
  'Used at the end of a production recovery, when the restore is the real database now.
   Naming it as production here is a person deciding that, which is the intent: recovery is
   not blocked, and it is not silent either.';


-- ════════════════════════════════════════════════════════════════════ the rules

CREATE TYPE scrub_strategy AS ENUM (
  'synthetic_name',    -- replaced from a vocabulary, via a salt discarded at the end
  'synthetic_email',   -- user<digest>@example.invalid, unique because the original was
  'redact_text',       -- replaced with filler of the same length, so layouts still break
  'hash_token',        -- an opaque digest; keeps uniqueness, keeps nothing else
  'hash_path',         -- the same, keeping the facility prefix the schema requires
  'remap_key',         -- a uuid rewritten as a digest, so a copy shares no key with production
  'scramble_password', -- a well-formed Argon2id digest of nothing anyone knows
  'scramble_digest',   -- a well-formed SHA-256 digest, likewise
  'shift_days',        -- moved by one offset for the whole database, so intervals survive
  'null_out',
  'keep'               -- deliberately, with a reason
);

CREATE TABLE scrub_rules (
  table_name   text NOT NULL,
  column_name  text NOT NULL,
  strategy     scrub_strategy NOT NULL,
  reason       text,
  PRIMARY KEY (table_name, column_name),
  FOREIGN KEY (table_name, column_name)
    REFERENCES data_classification (table_name, column_name) ON DELETE CASCADE,
  -- Keeping something is a decision and has to be argued for.
  CHECK (strategy <> 'keep' OR reason IS NOT NULL)
);

COMMENT ON CONSTRAINT scrub_rules_table_name_column_name_fkey ON scrub_rules IS
  'A rule can only exist for a column the classification knows about, so the two cannot
   drift into describing different schemas.';


-- ── residents ──────────────────────────────────────────────────────────────────
-- The name goes. The clinical shape stays, because a dev database where every resident
-- is calm and eats well is not one anybody can build a daily summary against.

INSERT INTO scrub_rules (table_name, column_name, strategy, reason) VALUES
 ('residents','id','remap_key','A uuid is meaningless on its own. A uuid that is the same in a development copy and in a production log line is a code assigned to the individual, and it is the join key that makes everything kept here attributable again.'),
 ('residents','display_name','synthetic_name',NULL),
 ('residents','external_patient_id','hash_token',NULL),
 ('residents','admitted_on','shift_days',NULL),
 ('residents','departed_on','shift_days',NULL),
 ('residents','baseline_mood','keep','A mood with no name attached is not information about anyone, and the summary rules are built against the distribution.'),
 ('residents','baseline_appetite','keep','As above.'),
 ('residents','baseline_sleep','keep','As above.');

-- ── care days ──────────────────────────────────────────────────────────────────
-- The note is the most sensitive free text in the product. Filler of the same length,
-- because a note that is always eleven characters long hides every layout bug a real one
-- would have found.

INSERT INTO scrub_rules (table_name, column_name, strategy, reason) VALUES
 ('care_days','id','remap_key','The same. A care day id in a log line and the same id in a developer''s database is one join away from the note.'),
 ('care_days','note','redact_text',NULL),
 ('care_days','care_date','shift_days',NULL),
 ('care_days','mood','keep','Clinical shape, detached from identity. See residents.baseline_mood.'),
 ('care_days','appetite','keep','As above.'),
 ('care_days','sleep','keep','As above.'),
 ('care_days','hygiene_shower','keep','A boolean with no name attached.'),
 ('care_days','hygiene_grooming','keep','As above.');

INSERT INTO scrub_rules (table_name, column_name, strategy, reason) VALUES
 ('care_day_meals','slot','keep','Part of the primary key, and one of three fixed values.'),
 ('care_day_meals','happened','keep','A boolean with no name attached.'),
 ('care_day_meals','amount','keep','Null here means "not observed", which is behaviour the app has to be tested against.'),
 ('care_day_concerns','concern','keep','Part of the primary key. A fixed vocabulary, detached from identity.');

-- ── medication ─────────────────────────────────────────────────────────────────

INSERT INTO scrub_rules (table_name, column_name, strategy, reason) VALUES
 ('medication_events','care_date','shift_days',NULL),
 ('medication_events','occurred_at','shift_days',NULL),
 ('medication_events','detail','redact_text',NULL),
 ('medication_events','source_ref','hash_token',NULL),
 ('medication_events','slot','keep','Three fixed values, part of the one-per-slot index.'),
 ('medication_events','status','keep','Clinical shape. The family-facing rules depend on the distribution of held and refused.');

-- ── media ──────────────────────────────────────────────────────────────────────
-- The path is the leak nobody expects: cedar/2025/frances-garden.jpg carries a name.

INSERT INTO scrub_rules (table_name, column_name, strategy, reason) VALUES
 ('media_objects','object_path','hash_path',NULL);

-- ── people who are not the patient ─────────────────────────────────────────────

INSERT INTO scrub_rules (table_name, column_name, strategy, reason) VALUES
 ('users','email','synthetic_email',NULL),
 ('users','display_name','synthetic_name',NULL),
 ('users','password_hash','scramble_password',NULL),
 ('sessions','device_label','redact_text',NULL),
 ('sessions','refresh_hash','scramble_digest',NULL),
 ('user_tokens','token_hash','scramble_digest',NULL),
 ('resident_contacts','relation','keep','A relationship type with both parties anonymised. The access model is built on it and cannot be tested without it.');

-- ── the trail ──────────────────────────────────────────────────────────────────

INSERT INTO scrub_rules (table_name, column_name, strategy, reason) VALUES
 ('audit_events','resident_id','remap_key','Not a foreign key, so it does not cascade - and it arrives at the same value by the same digest, which is what keeps the trail joinable to the records it describes.'),
 ('audit_events','subject_id','remap_key','As above.'),
 ('audit_events','ip_hash','null_out',NULL),
 ('audit_events','occurred_at','shift_days','Operational, but shifted with everything else so the trail and the records it describes stay in step.');


CREATE VIEW unscrubbed_columns AS
SELECT dc.table_name, dc.column_name, dc.class, dc.note
FROM data_classification dc
LEFT JOIN scrub_rules sr
  ON sr.table_name = dc.table_name AND sr.column_name = dc.column_name
WHERE dc.class IN ('phi', 'identifying', 'secret')
  AND sr.column_name IS NULL
ORDER BY dc.table_name, dc.column_name;

COMMENT ON VIEW unscrubbed_columns IS
  'Must be empty. A column holding PHI with no scrub rule is a column that would travel
   into a developer''s laptop the next time somebody restores a snapshot.';


-- ════════════════════════════════════════════════════════════════════ the replacements

CREATE OR REPLACE FUNCTION scrub_fake_name(original text, salt text)
RETURNS text LANGUAGE sql IMMUTABLE
  SET search_path = pg_catalog, public AS $$
  SELECT CASE WHEN original IS NULL THEN NULL ELSE
    (ARRAY['Alice','Beatrice','Cathy','Dorothy','Evelyn','Frances','Grace','Harriet',
           'Irene','Josephine','Katherine','Lillian','Margaret','Nora','Opal','Pearl',
           'Quinn','Ruth','Sylvia','Thelma','Ursula','Vera','Wanda','Yvonne'])
      [(abs(hashtext(salt || original)) % 24) + 1]
    || ' ' ||
    (ARRAY['Adler','Bennett','Carr','Dawson','Ellis','Fletcher','Grant','Hale',
           'Ingram','Jarvis','Keane','Lowell','Marsh','Norton','Oakley','Pryor'])
      [(abs(hashtext(salt || original || 'x')) % 16) + 1]
  END
$$;

COMMENT ON FUNCTION scrub_fake_name(text, text) IS
  'The salt is generated per run and discarded when the run ends, so the mapping from a
   real name to its replacement exists only for the length of the transaction.';

CREATE OR REPLACE FUNCTION scrub_redact(original text)
RETURNS text LANGUAGE sql IMMUTABLE
  SET search_path = pg_catalog, public AS $$
  SELECT CASE
    WHEN original IS NULL THEN NULL
    WHEN original =  ''   THEN ''
    ELSE left(repeat('Removed for non-production use. ', 60), length(original))
  END
$$;

COMMENT ON FUNCTION scrub_redact(text) IS
  'Same length as the original, deliberately. A dev database where every care note is
   eleven characters long hides every layout bug a real one would have found. Length is
   the one thing it leaks, and length is not a clinical fact.';


-- ════════════════════════════════════════════════════════════════════ the scan
--
-- Every column of every table, cast to text. Not only the columns believed to hold PHI:
-- the interesting leaks are the ones nobody classified, which is exactly why this does not
-- read the classification table.

CREATE OR REPLACE FUNCTION phi_residue(patterns text[])
RETURNS TABLE (table_name text, column_name text, pattern text, hits bigint)
LANGUAGE plpgsql STABLE
  SET search_path = pg_catalog, public AS $$
DECLARE
  c record;
  p text;
  n bigint;
BEGIN
  FOR c IN
    SELECT k.table_name AS t, k.column_name AS col
    FROM information_schema.columns k
    JOIN information_schema.tables tb
      ON tb.table_schema = k.table_schema AND tb.table_name = k.table_name
    WHERE k.table_schema = 'public' AND tb.table_type = 'BASE TABLE'
    ORDER BY k.table_name, k.ordinal_position
  LOOP
    FOREACH p IN ARRAY patterns LOOP
      EXECUTE format('SELECT count(*) FROM %I WHERE %I::text ILIKE %L',
                     c.t, c.col, '%' || p || '%') INTO n;
      IF n > 0 THEN
        table_name := c.t; column_name := c.col; pattern := p; hits := n;
        RETURN NEXT;
      END IF;
    END LOOP;
  END LOOP;
END; $$;

COMMENT ON FUNCTION phi_residue(text[]) IS
  'Returns nothing when the scrub was complete. Prove it is capable of returning something
   before believing an empty result — the invariants do exactly that.';


-- ════════════════════════════════════════════════════════════════════ on what basis
--
-- The scrub replaces names, re-keys identifiers and moves every date by one offset. That
-- last one is deliberate and useful - intervals survive, so a two-week report still has
-- two weeks in it - and it is also the reason this is not de-identified data under Safe
-- Harbor, which requires every element of a date related to an individual to be removed
-- except the year. A shifted date is a date, and the interval between an admission and a
-- departure is preserved exactly.
--
-- So the copy is closer to a limited data set, which is still protected health information
-- and still needs a data use agreement. The honest route is the other one the rule offers:
-- an expert determination that the residual risk, after synthetic names, re-keyed
-- identifiers and shifted dates, is very small. That is a document with a signature on it
-- and not a constraint, so what is here is the absence of it, named.

CREATE TYPE deidentification_method AS ENUM ('undetermined', 'safe_harbor', 'expert_determination');

CREATE TABLE deidentification_basis (
  only_row     boolean PRIMARY KEY DEFAULT true CHECK (only_row),
  method       deidentification_method NOT NULL,
  determined_by text,
  determined_on date,
  note         text,

  -- A determination is somebody's professional judgement, so it has their name on it.
  CONSTRAINT a_determination_is_signed CHECK (
    method <> 'expert_determination'
    OR (determined_by IS NOT NULL AND determined_on IS NOT NULL))
);

INSERT INTO deidentification_basis (method, note) VALUES
('undetermined',
 'The scrub is not Safe Harbor: dates are shifted rather than removed, which keeps the intervals a developer needs and keeps the data a limited data set rather than de-identified. An expert determination under 164.514(b)(1) is the route that fits what this actually does, and nobody has signed one. Listed here the way never_drilled and vendor_gaps are listed: an honest gap with a name on it, rather than a claim nobody checked.');

CREATE VIEW deidentification_undetermined AS
SELECT method, note FROM deidentification_basis WHERE method = 'undetermined';

COMMENT ON VIEW deidentification_undetermined IS
  'Expected to have a row today. Empty before a scrubbed copy is treated as anything other
   than protected health information - which, until this is signed, it is.';


-- ════════════════════════════════════════════════════════════════════ the scrub

CREATE OR REPLACE FUNCTION scrub_phi(confirm_database text)
RETURNS TABLE (what text, changed bigint)
LANGUAGE plpgsql
  SET search_path = pg_catalog, public AS $$
DECLARE
  env        deployment_environment;
  salt       text := gen_random_uuid()::text;
  shift      integer;
  r          record;
  ix         record;
  col        text;
  expr       text;
  n          bigint;
  total      bigint := 0;
  cols       integer := 0;
  idx_defs   text[] := '{}';
  forced     text[] := '{}';
BEGIN
  -- Two locks on the door, because the mistake this prevents cannot be undone.
  IF confirm_database IS DISTINCT FROM current_database() THEN
    RAISE EXCEPTION 'refusing: called with %, connected to %',
      coalesce(confirm_database, '<null>'), current_database();
  END IF;

  SELECT environment INTO env FROM deployment;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'refusing: this database has not said which environment it is';
  END IF;
  IF env = 'production' THEN
    RAISE EXCEPTION 'refusing: this database is labelled production';
  END IF;

  IF EXISTS (SELECT 1 FROM unscrubbed_columns) THEN
    RAISE EXCEPTION 'refusing: % classified columns have no scrub rule',
      (SELECT count(*) FROM unscrubbed_columns);
  END IF;

  -- One offset for the whole database, between one and three years, so every interval a
  -- report depends on survives and no date is where it was.
  shift := -(365 + (abs(hashtext(salt)) % 730));

  -- The application is not the one running this, and the policies that stop the
  -- application also stop the owner. Lifted for the transaction and put back below; a
  -- failure anywhere rolls the whole thing back, DDL included. The credential triggers on
  -- users, sessions and user_tokens are deliberately not lifted: what the scrub writes
  -- there has to survive the same check a real credential does.
  FOR r IN SELECT c.relname FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
           WHERE ns.nspname = 'public' AND c.relrowsecurity AND c.relforcerowsecurity
  LOOP
    forced := forced || r.relname;
    EXECUTE format('ALTER TABLE %I NO FORCE ROW LEVEL SECURITY', r.relname);
    EXECUTE format('ALTER TABLE %I DISABLE TRIGGER USER', r.relname);
  END LOOP;

  -- A uniform date shift can collide with a row that has not been shifted yet, halfway
  -- through the statement. The indexes come off and go back on, which also proves the
  -- shifted data still satisfies them: if it did not, creating the index fails and the
  -- whole scrub is rolled back.
  FOR ix IN
    SELECT i.relname AS name, pg_get_indexdef(i.oid) AS def
    FROM pg_index x
    JOIN pg_class i  ON i.oid = x.indexrelid
    JOIN pg_class c  ON c.oid = x.indrelid
    JOIN pg_namespace ns ON ns.oid = c.relnamespace
    LEFT JOIN pg_constraint con ON con.conindid = i.oid
    WHERE ns.nspname = 'public' AND x.indisunique AND con.oid IS NULL
      AND c.relname IN (SELECT sr.table_name FROM scrub_rules sr WHERE sr.strategy = 'shift_days')
  LOOP
    idx_defs := idx_defs || ix.def;
    EXECUTE format('DROP INDEX %I', ix.name);
  END LOOP;

  FOR r IN
    SELECT sr.table_name AS t, sr.column_name AS c, sr.strategy AS s, k.data_type AS dt
    FROM scrub_rules sr
    JOIN information_schema.columns k
      ON k.table_schema = 'public' AND k.table_name = sr.table_name
     AND k.column_name = sr.column_name
    WHERE sr.strategy <> 'keep'
    ORDER BY sr.table_name, sr.column_name
  LOOP
    col := quote_ident(r.c);
    expr := CASE r.s
      WHEN 'synthetic_name'  THEN format('scrub_fake_name(%s, %L)', col, salt)
      WHEN 'synthetic_email' THEN format($e$CASE WHEN %s IS NULL THEN NULL ELSE 'user' || substr(md5(%L || %s), 1, 12) || '@example.invalid' END$e$, col, salt, col)
      WHEN 'redact_text'     THEN format('scrub_redact(%s)', col)
      WHEN 'hash_token'      THEN format('CASE WHEN %s IS NULL THEN NULL ELSE substr(md5(%L || %s), 1, 16) END', col, salt, col)
      -- An object path begins with the facility it belongs to, and the schema enforces
      -- that. A plain digest would be a value the table refuses, so the scrub keeps the
      -- prefix and hashes the rest - which is also what a developer wants to see.
      WHEN 'hash_path'       THEN format('CASE WHEN %s IS NULL THEN NULL ELSE facility_id::text || ''/'' || substr(md5(%L || %s), 1, 16) END', col, salt, col)
      -- A uuid derived from the salt and the original. Unique because the original was,
      -- consistent inside the copy so every join still holds, and derived from a salt
      -- nobody keeps - so the copy and production share no key at all.
      WHEN 'remap_key'       THEN format('CASE WHEN %s IS NULL THEN NULL ELSE md5(%L || %s::text)::uuid END', col, salt, col)
      -- Shaped correctly and derived from nothing: the schema refuses a credential column
      -- that is not a digest, so a sentinel string would fail the constraint on its way in.
      -- Correct shape is also what a developer needs - a login path that never sees a
      -- realistic hash is a login path nobody has tested.
      WHEN 'scramble_password' THEN format($p$CASE WHEN %s IS NULL THEN NULL ELSE '$argon2id$v=19$m=65536,t=3,p=4$' || substr(md5(%L || %s), 1, 22) || '$' || substr(md5(%L || %s) || md5(%s || %L), 1, 43) END$p$, col, salt, col, salt, col, col, salt)
      WHEN 'scramble_digest'   THEN format('CASE WHEN %s IS NULL THEN NULL ELSE md5(%L || %s) || md5(%s || %L) END', col, salt, col, col, salt)
      WHEN 'null_out'        THEN 'NULL'
      WHEN 'shift_days'      THEN CASE WHEN r.dt = 'date'
                                       THEN format('%s + %s', col, shift)
                                       ELSE format('%s + make_interval(days => %s)', col, shift) END
    END;

    EXECUTE format('UPDATE %I SET %s = %s', r.t, col, expr);
    GET DIAGNOSTICS n = ROW_COUNT;
    total := total + n;
    cols  := cols + 1;
  END LOOP;

  FOREACH expr IN ARRAY idx_defs LOOP
    EXECUTE expr;
  END LOOP;

  FOREACH col IN ARRAY forced LOOP
    EXECUTE format('ALTER TABLE %I ENABLE TRIGGER USER', col);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', col);
  END LOOP;

  INSERT INTO scrub_runs (environment, shift_days, columns_changed, rows_changed)
  VALUES (env, shift, cols, total);

  -- The copy is now this database rather than a snapshot of another one.
  UPDATE deployment SET database_name   = current_database(),
                        cluster_id      = deployment_cluster_id(),
                        phi_scrubbed_at = now();

  what := 'columns rewritten'; changed := cols;  RETURN NEXT;
  what := 'rows touched';      changed := total; RETURN NEXT;
  what := 'columns kept, with a reason';
  changed := (SELECT count(*) FROM scrub_rules WHERE strategy = 'keep'); RETURN NEXT;
  RETURN;
END; $$;

COMMENT ON FUNCTION scrub_phi(text) IS
  'Takes the name of the database it is about to rewrite and refuses if that is not the one
   it is connected to, so running it against production requires deliberately typing the
   production database name. The environment label is the second lock.';


-- ════════════════════════════════════════════════════════════════════ privileges
--
-- Restoring and scrubbing a snapshot is an operator action on a non-production copy. The
-- application role has no part in it and cannot reach any of it.

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dailycare_app') THEN
    REVOKE ALL ON deployment, scrub_rules, scrub_runs FROM dailycare_app;
    GRANT  SELECT ON deployment TO dailycare_app;
  END IF;
END $$;

REVOKE EXECUTE ON FUNCTION scrub_phi(text)      FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION phi_residue(text[])  FROM PUBLIC;

-- ════════════════════════════════════════════════════════════════════ classification
--
-- A table added to this schema is a table the PHI inventory has to have an answer for,
-- and "operational" is an answer that has to be written down rather than inferred from
-- nobody having said otherwise. unclassified_columns is checked by the suites.

-- deployment: Which environment this database is, and where it was written.
INSERT INTO data_classification (table_name, column_name, class, note) VALUES
 ('deployment','cluster_id','operational',NULL),
 ('deployment','database_name','operational',NULL),
 ('deployment','environment','operational',NULL),
 ('deployment','label','operational',NULL),
 ('deployment','only_row','operational',NULL),
 ('deployment','phi_scrubbed_at','operational',NULL),
 ('deployment','set_at','operational',NULL);

-- scrub_rules: What happens to each column when a snapshot is made safe to develop against.
INSERT INTO data_classification (table_name, column_name, class, note) VALUES
 ('scrub_rules','column_name','operational',NULL),
 ('scrub_rules','reason','operational',NULL),
 ('scrub_rules','strategy','operational',NULL),
 ('scrub_rules','table_name','operational',NULL);

-- scrub_runs: When a copy was scrubbed, and by whom. Counts only.
INSERT INTO data_classification (table_name, column_name, class, note) VALUES
 ('scrub_runs','columns_changed','operational',NULL),
 ('scrub_runs','database_name','operational',NULL),
 ('scrub_runs','environment','operational',NULL),
 ('scrub_runs','id','operational',NULL),
 ('scrub_runs','ran_at','operational',NULL),
 ('scrub_runs','ran_by','operational',NULL),
 ('scrub_runs','rows_changed','operational',NULL),
 ('scrub_runs','shift_days','operational',NULL);

