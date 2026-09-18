-- DailyCare production schema
--
-- PostgreSQL. Written for Milestone 2, and written once: every later milestone adds to
-- this rather than reshaping it. The decisions worth arguing with are commented where
-- they are made rather than collected at the end.
--
-- Three rules run through the whole file.
--
--   Every row belongs to a facility. Multi-tenancy is here from the first migration
--   because adding a tenant column to a populated table is a different kind of job.
--
--   Identity is never a name. Every key is a generated UUID, so a resident keeps their
--   identity through a name correction, a transfer, or a readmission.
--
--   A relationship is a row with a type, never a boolean on a person. InkTree learned
--   this the expensive way — `relation = 'self'` rather than `is_user` — and DailyCare
--   uses the same shape so the two models can be reconciled later instead of translated.

CREATE EXTENSION IF NOT EXISTS "pgcrypto";   -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS "citext";     -- case-insensitive email


-- ════════════════════════════════════════════════════════════════════ enums
--
-- Enumerated in the database rather than left as free text, because every one of these
-- is a closed set the product depends on. A typo in a status column is a silent bug in
-- a care record.

CREATE TYPE facility_role AS ENUM (
  'caregiver',        -- files care days for the residents assigned to them
  'care_manager'      -- sees every resident in the facility, manages people and access
);

-- How a person is related to a resident. Deliberately an enum rather than a set of
-- booleans: 'self' is a relationship like any other, and the moment it becomes a flag
-- somebody writes `WHERE is_self = false` and silently drops a row that mattered.
CREATE TYPE resident_relation AS ENUM (
  'self',             -- the resident's own account, if they ever hold one
  'spouse',
  'child',
  'sibling',
  'other_family',
  'friend',
  'power_of_attorney'
);

CREATE TYPE access_state AS ENUM (
  'invited',          -- invitation sent, not yet accepted
  'active',
  'revoked'
);

CREATE TYPE meal_slot AS ENUM ('breakfast', 'lunch', 'dinner');

-- Optional by design. A caregiver who ticks the meal and moves on has filed a complete
-- record; the amount is extra information, not a required field.
CREATE TYPE meal_amount AS ENUM ('a_bit', 'half', 'most', 'all');

CREATE TYPE medication_slot AS ENUM ('am', 'pm', 'supplemental');

-- Not a boolean. "Not given" and "refused" are different clinical facts, and a system
-- that records both as `false` cannot tell a family which one happened.
CREATE TYPE medication_status AS ENUM (
  'given',
  'held',             -- withheld deliberately, usually on instruction
  'refused',          -- the resident declined
  'not_recorded'      -- nobody has said either way yet
);

-- Where a medication fact came from. The whole point of the event model: a caregiver's
-- tick and a MedTech's PointClickCare entry are both valid, and the family should be
-- able to see which one they are reading.
CREATE TYPE medication_source AS ENUM (
  'caregiver',
  'pointclickcare'
);

CREATE TYPE mood AS ENUM ('calm', 'anxious', 'confused', 'withdrawn', 'agitated');
CREATE TYPE appetite AS ENUM ('good', 'fair', 'poor', 'refused');
CREATE TYPE sleep_quality AS ENUM ('slept_well', 'restless', 'up_a_lot', 'didnt_sleep');

CREATE TYPE concern AS ENUM (
  'wandering',
  'sundowning',
  'fall_or_near_fall',
  'pain',
  'skin_concern'
);


-- ════════════════════════════════════════════════════════════════════ tenancy

CREATE TABLE facilities (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name         text NOT NULL,
  timezone     text NOT NULL,   -- IANA name. A care day is a local calendar day, and a
                                -- facility in Texas rolls over at a different instant
                                -- from one in California.
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  archived_at  timestamptz     -- a closed facility is retained, not deleted
);

COMMENT ON COLUMN facilities.timezone IS
  'Care days are local calendar days. Every date boundary in the product resolves here.';


-- ════════════════════════════════════════════════════════════════════ identity
--
-- A user is an authentication identity and nothing else. What they may do comes from
-- the membership rows below, never from a column here — the same person can be a
-- caregiver at one facility and a daughter at another.

-- ════════════════════════════════════════════════════════════════════ credentials
--
-- What a credential column may contain, written once and used by both the constraint that
-- enforces it and the trigger that reports it.

CREATE OR REPLACE FUNCTION is_argon2id(candidate text) RETURNS boolean
LANGUAGE sql IMMUTABLE
  SET search_path = pg_catalog, public AS $$
  SELECT candidate ~ '^\$argon2id\$v=19\$m=[0-9]+,t=[0-9]+,p=[0-9]+\$[A-Za-z0-9+/]{16,}\$[A-Za-z0-9+/]{16,}$'
$$;

CREATE OR REPLACE FUNCTION is_sha256_hex(candidate text) RETURNS boolean
LANGUAGE sql IMMUTABLE
  SET search_path = pg_catalog, public AS $$
  SELECT candidate ~ '^[0-9a-f]{64}$'
$$;

-- A check constraint is the right enforcement and the wrong error message. PostgreSQL
-- reports the failing row in full, so the rejection of a plaintext password is itself a
-- message containing that password, on its way to wherever the application sends errors.
-- That is precisely the accidental exposure the vendor register names Cloud Logging for,
-- and it would have been introduced by the constraint meant to prevent the problem.
--
-- So the constraint stays as the backstop and this runs first, refusing without repeating
-- the value. Both use the same predicate, so they cannot come to disagree, and the
-- constraint still holds if somebody disables the trigger.

CREATE OR REPLACE FUNCTION reject_unhashed_credential() RETURNS trigger
LANGUAGE plpgsql
  SET search_path = pg_catalog, public AS $$
DECLARE
  value text := to_jsonb(NEW) ->> TG_ARGV[0];
  ok    boolean;
BEGIN
  IF value IS NULL THEN RETURN NEW; END IF;
  EXECUTE format('SELECT %I($1)', TG_ARGV[1]) INTO ok USING value;
  IF NOT ok THEN
    RAISE EXCEPTION '%.% is not %', TG_TABLE_NAME, TG_ARGV[0], TG_ARGV[2]
      USING ERRCODE = 'check_violation',
            HINT = 'The value is deliberately not repeated here. A database error carrying a credential ends up wherever errors are logged.';
  END IF;
  RETURN NEW;
END; $$;


CREATE TABLE users (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email              citext NOT NULL UNIQUE,
  password_hash      text,          -- null while an invitation is outstanding
  display_name       text NOT NULL,
  email_verified_at  timestamptz,
  last_seen_at       timestamptz,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  deactivated_at     timestamptz,   -- sign-in refused, records they filed are untouched

  -- A password that reaches this column in any form other than an Argon2id digest is
  -- refused by the database. "We hash credentials" is otherwise a property of whichever
  -- handler happened to write the row, and the day somebody adds a second one - an admin
  -- import, a seeding script, a migration - it stops being true quietly.
  --
  -- Pinning the algorithm here is deliberate. Changing how a password is stored should
  -- be a migration somebody wrote on purpose, not a line in a handler.
  CONSTRAINT password_hash_is_argon2id
    CHECK (password_hash IS NULL OR is_argon2id(password_hash))
);

-- Password reset and invitation acceptance both land here. Single-use, short-lived, and
-- the token itself is never stored — only its hash, so a database read cannot be
-- replayed as a password reset.
CREATE TABLE user_tokens (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  purpose     text NOT NULL CHECK (purpose IN ('password_reset', 'invitation', 'email_verification')),
  -- Same rule as a session. An invitation or reset link is a bearer credential: the only
  -- copy that should exist outside the recipient's inbox is a digest.
  token_hash  text NOT NULL CHECK (is_sha256_hex(token_hash)),
  expires_at  timestamptz NOT NULL,
  consumed_at timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX ON user_tokens (user_id, purpose) WHERE consumed_at IS NULL;
CREATE INDEX ON user_tokens (token_hash);


CREATE TABLE sessions (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  -- The token itself is shown to the client once and never stored. What is kept is a
  -- SHA-256 of it, and the constraint is what makes that a fact about the table rather
  -- than about the code that last wrote to it: a raw token is the wrong shape and is
  -- refused. A stolen dump of this table cannot be replayed as a session.
  refresh_hash    text NOT NULL CHECK (is_sha256_hex(refresh_hash)),
  device_label    text,          -- "iPhone 15", for a user reviewing their own sessions
  issued_at       timestamptz NOT NULL DEFAULT now(),
  last_used_at    timestamptz NOT NULL DEFAULT now(),
  expires_at      timestamptz NOT NULL,
  revoked_at      timestamptz
);

CREATE INDEX ON sessions (user_id) WHERE revoked_at IS NULL;

COMMENT ON TABLE sessions IS
  'Multi-device persistence lives here. Signing in on a second phone adds a row; it does
   not move anything. Reinstalling and signing back in recovers the account rather than
   the device.';


-- ════════════════════════════════════════════════════════════════════ staff roles

-- The polite door, attached once all three credential tables exist. The check constraints
-- on those columns are the enforcement; these only make the refusal safe to log.

CREATE TRIGGER reject_plaintext_password BEFORE INSERT OR UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION
  reject_unhashed_credential('password_hash', 'is_argon2id', 'an Argon2id digest');

CREATE TRIGGER reject_plaintext_refresh_token BEFORE INSERT OR UPDATE ON sessions
  FOR EACH ROW EXECUTE FUNCTION
  reject_unhashed_credential('refresh_hash', 'is_sha256_hex', 'a SHA-256 digest');

CREATE TRIGGER reject_plaintext_token BEFORE INSERT OR UPDATE ON user_tokens
  FOR EACH ROW EXECUTE FUNCTION
  reject_unhashed_credential('token_hash', 'is_sha256_hex', 'a SHA-256 digest');


CREATE TABLE facility_members (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  facility_id   uuid NOT NULL REFERENCES facilities(id) ON DELETE RESTRICT,
  user_id       uuid NOT NULL REFERENCES users(id)      ON DELETE RESTRICT,
  role          facility_role NOT NULL,
  state         access_state  NOT NULL DEFAULT 'invited',
  invited_by    uuid REFERENCES users(id),
  started_at    timestamptz NOT NULL DEFAULT now(),
  ended_at      timestamptz,   -- a caregiver who leaves. The rows they filed stay.
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (facility_id, user_id, role)
);

CREATE INDEX ON facility_members (facility_id) WHERE ended_at IS NULL;
CREATE INDEX ON facility_members (user_id)     WHERE ended_at IS NULL;

COMMENT ON TABLE facility_members IS
  'Deactivating a caregiver ends the membership. It never deletes the user and never
   touches the care days they filed — those are the facility''s record, not theirs.';


-- ════════════════════════════════════════════════════════════════════ residents

CREATE TABLE residents (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  facility_id   uuid NOT NULL REFERENCES facilities(id) ON DELETE RESTRICT,

  -- PHI. Given name only in the product today; the column is wide enough for a full
  -- legal name because PointClickCare matching will need one.
  display_name  text NOT NULL,

  -- The resident's identity in the facility's clinical system, when there is one.
  -- Kept alongside rather than used as the key: DailyCare must work for a facility with
  -- no EHR, and a resident must survive being rematched.
  external_source     medication_source,
  external_patient_id text,

  -- What a normal day looks like for this person. The daily summary reports mood,
  -- appetite and sleep only when they differ from these.
  baseline_mood      mood          NOT NULL DEFAULT 'calm',
  baseline_appetite  appetite      NOT NULL DEFAULT 'fair',
  baseline_sleep     sleep_quality NOT NULL DEFAULT 'restless',

  admitted_on   date,
  departed_on   date,          -- moved out. Records are retained under the policy below.
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (external_source, external_patient_id),

  -- Redundant against the primary key, and there for one reason: it lets every child row
  -- reference the resident and the facility together, so the pair cannot disagree. See the
  -- composite foreign keys below.
  UNIQUE (id, facility_id)
);

CREATE INDEX ON residents (facility_id) WHERE departed_on IS NULL;

COMMENT ON COLUMN residents.display_name IS 'PHI.';
COMMENT ON COLUMN residents.external_patient_id IS
  'PHI. The clinical system''s own identifier, stored so medication events can be matched
   without DailyCare guessing from names.';


-- Which caregiver is responsible for which resident. Changes as shifts change, so it is
-- a row with a life rather than a column.
CREATE TABLE assignments (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  facility_id         uuid NOT NULL REFERENCES facilities(id) ON DELETE RESTRICT,
  resident_id         uuid NOT NULL,
  facility_member_id  uuid NOT NULL REFERENCES facility_members(id) ON DELETE RESTRICT,
  started_at          timestamptz NOT NULL DEFAULT now(),
  ended_at            timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),

  -- The resident and the facility together, so a row cannot name one facility and a
  -- resident who is in another. Two separate references each held; the pair did not.
  FOREIGN KEY (resident_id, facility_id)
    REFERENCES residents (id, facility_id) ON DELETE RESTRICT
);

CREATE INDEX ON assignments (resident_id)        WHERE ended_at IS NULL;
CREATE INDEX ON assignments (facility_member_id) WHERE ended_at IS NULL;


-- ════════════════════════════════════════════════════════════════════ family access
--
-- The foundation Milestone 4 builds the family app on. Access is granted to a person
-- against a resident and can be withdrawn. Possession of a link grants nothing — the
-- link is a route, the row below is the permission.

CREATE TABLE resident_contacts (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  facility_id   uuid NOT NULL REFERENCES facilities(id) ON DELETE RESTRICT,
  resident_id   uuid NOT NULL,
  user_id       uuid NOT NULL REFERENCES users(id)      ON DELETE RESTRICT,

  relation      resident_relation NOT NULL,
  state         access_state      NOT NULL DEFAULT 'invited',

  -- Who let them in, and when it was taken away. Both are answers a reviewer will ask
  -- for, and neither can be reconstructed afterwards if they are not written down.
  granted_by    uuid REFERENCES users(id),
  granted_at    timestamptz,
  revoked_by    uuid REFERENCES users(id),
  revoked_at    timestamptz,

  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (resident_id, user_id),

  -- The resident and the facility together, so a row cannot name one facility and a
  -- resident who is in another. Two separate references each held; the pair did not.
  FOREIGN KEY (resident_id, facility_id)
    REFERENCES residents (id, facility_id) ON DELETE RESTRICT
);

CREATE INDEX ON resident_contacts (user_id)     WHERE state = 'active';
CREATE INDEX ON resident_contacts (resident_id) WHERE state = 'active';

COMMENT ON TABLE resident_contacts IS
  'A family member may hold rows for several residents — two parents in the same building
   is the ordinary case. Authorisation is per resident, never per family.';


-- ════════════════════════════════════════════════════════════════════ care record
--
-- One row per resident per local calendar day. Amendable, and an amendment never
-- overwrites: a care record is corrected the way a clinical note is, by adding.

CREATE TABLE care_days (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  facility_id    uuid NOT NULL REFERENCES facilities(id) ON DELETE RESTRICT,
  resident_id    uuid NOT NULL,

  -- The day being described, in the facility's timezone. Not the day it was filed:
  -- backdating up to two weeks is normal, and the difference is visible in the product.
  care_date      date NOT NULL,

  -- PHI, all of it.
  mood           mood          NOT NULL,
  appetite       appetite      NOT NULL,
  sleep          sleep_quality NOT NULL,
  note           text NOT NULL DEFAULT '',

  hygiene_shower   boolean NOT NULL DEFAULT false,
  hygiene_grooming boolean NOT NULL DEFAULT false,

  filed_by       uuid NOT NULL REFERENCES users(id),
  filed_at       timestamptz NOT NULL DEFAULT now(),

  -- Set when this row has been superseded by a correction. The superseding row points
  -- back through amends_id below, so the whole chain is readable in either direction.
  superseded_at  timestamptz,
  amends_id      uuid REFERENCES care_days(id),

  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),

  -- The resident and the facility together, so a row cannot name one facility and a
  -- resident who is in another. Two separate references each held; the pair did not.
  FOREIGN KEY (resident_id, facility_id)
    REFERENCES residents (id, facility_id) ON DELETE RESTRICT
);

-- One current row per resident per day. Superseded rows are exempt, which is what makes
-- the amendment chain possible without a second table.
CREATE UNIQUE INDEX care_days_current_per_day
  ON care_days (resident_id, care_date)
  WHERE superseded_at IS NULL;

CREATE INDEX ON care_days (resident_id, care_date DESC);
CREATE INDEX ON care_days (facility_id, care_date DESC);

COMMENT ON TABLE care_days IS
  'Correcting a filed day inserts a new row with amends_id set and stamps the old one
   superseded. Nothing is updated in place, so the original is always recoverable and the
   family can be shown that a correction happened rather than a different past.';


CREATE TABLE care_day_meals (
  care_day_id  uuid NOT NULL REFERENCES care_days(id) ON DELETE CASCADE,
  slot         meal_slot NOT NULL,
  happened     boolean NOT NULL DEFAULT false,
  amount       meal_amount,   -- null is "not observed", which is a real answer
  PRIMARY KEY (care_day_id, slot),
  CHECK (amount IS NULL OR happened)   -- an amount without the meal is nonsense
);

CREATE TABLE care_day_concerns (
  care_day_id  uuid NOT NULL REFERENCES care_days(id) ON DELETE CASCADE,
  concern      concern NOT NULL,
  PRIMARY KEY (care_day_id, concern)
);


-- ════════════════════════════════════════════════════════════════════ medication
--
-- Not a column on the care day. Medication is the one fact in this product that may
-- arrive from somewhere else — the MedTech records it in PointClickCare on a different
-- round, on a different schedule, and the care manager currently reconciles the two by
-- hand. Modelling it as an event with a source is what removes that step later.

CREATE TABLE medication_events (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  facility_id   uuid NOT NULL REFERENCES facilities(id) ON DELETE RESTRICT,
  resident_id   uuid NOT NULL,

  care_date     date NOT NULL,            -- the local day this belongs to
  slot          medication_slot NOT NULL,
  status        medication_status NOT NULL,

  -- Two timestamps, deliberately. An audit trail has to distinguish when a dose was
  -- given from when the system was told about it, and a medication round is documented
  -- on a different rhythm from a caregiver's shift.
  occurred_at   timestamptz,
  recorded_at   timestamptz NOT NULL DEFAULT now(),

  source        medication_source NOT NULL,
  source_ref    text,          -- the external system's own resource id
  recorded_by   uuid REFERENCES users(id),   -- null when the source is not a DailyCare user

  -- Free text for a supplemental dose. Only meaningful for slot = 'supplemental'.
  detail        text,

  created_at    timestamptz NOT NULL DEFAULT now(),
  CHECK (source = 'caregiver' OR source_ref IS NOT NULL),
  CHECK (slot <> 'supplemental' OR detail IS NOT NULL),

  -- The resident and the facility together, so a row cannot name one facility and a
  -- resident who is in another. Two separate references each held; the pair did not.
  FOREIGN KEY (resident_id, facility_id)
    REFERENCES residents (id, facility_id) ON DELETE RESTRICT
);

-- The scheduled slots are one per resident per day. Supplemental doses are not, so they
-- are excluded from the constraint rather than forced into it.
CREATE UNIQUE INDEX medication_events_one_per_slot
  ON medication_events (resident_id, care_date, slot)
  WHERE slot <> 'supplemental';

CREATE INDEX ON medication_events (resident_id, care_date DESC);
CREATE INDEX ON medication_events (source, source_ref);

COMMENT ON COLUMN medication_events.source IS
  'When this is pointclickcare the row is read-only in DailyCare and shown with an
   attribution line. The caregiver is never asked to re-enter what the MedTech filed.';


-- ════════════════════════════════════════════════════════════════════ media
--
-- The object itself lives in a private GCS bucket. This table holds the reference and
-- the authorisation context; a signed URL is minted per request, after the caller's
-- access to the resident has been checked, and never stored.

CREATE TABLE media_objects (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  facility_id    uuid NOT NULL REFERENCES facilities(id) ON DELETE RESTRICT,
  resident_id    uuid NOT NULL,
  care_day_id    uuid REFERENCES care_days(id) ON DELETE SET NULL,

  bucket         text NOT NULL,
  object_path    text NOT NULL,
  content_type   text NOT NULL,
  byte_size      bigint NOT NULL,
  checksum       text,

  uploaded_by    uuid NOT NULL REFERENCES users(id),
  created_at     timestamptz NOT NULL DEFAULT now(),
  deleted_at     timestamptz,   -- set when the object has actually been removed from GCS
  UNIQUE (bucket, object_path),

  -- The path begins with the facility the row belongs to. The application generates it;
  -- this is what stops a caller sending one. A row pointing at another building's object
  -- would be a read of that building's photograph through a link this row minted.
  CONSTRAINT object_path_is_under_its_facility
    CHECK (object_path LIKE facility_id::text || '/%'),

  -- The resident and the facility together, so a row cannot name one facility and a
  -- resident who is in another. Two separate references each held; the pair did not.
  FOREIGN KEY (resident_id, facility_id)
    REFERENCES residents (id, facility_id) ON DELETE RESTRICT
);

CREATE INDEX ON media_objects (resident_id) WHERE deleted_at IS NULL;
CREATE INDEX ON media_objects (care_day_id);

COMMENT ON TABLE media_objects IS
  'Photos are kept at the resolution they were taken. Downscaling is cheap now and
   impossible to undo later, when a family is offered a real download.';


-- ════════════════════════════════════════════════════════════════════ audit
--
-- Who touched which resident''s record, and when. Written for every read as well as every
-- write: a reviewer asks who has seen a record at least as often as who changed one.
-- Append-only by intent; no update or delete path exists in the application.

CREATE TABLE audit_events (
  id            bigserial PRIMARY KEY,
  occurred_at   timestamptz NOT NULL DEFAULT now(),

  actor_user_id uuid REFERENCES users(id),   -- null for scheduled jobs
  actor_role    text,                        -- role in force at the time, not now
  facility_id   uuid REFERENCES facilities(id),

  action        text NOT NULL,               -- 'care_day.read', 'resident.update', ...
  -- A table name, not a sentence. audit_read() checks it against the classification; this
  -- keeps free text out of the trail by any other route, including a future caller.
  subject_type  text NOT NULL CHECK (subject_type ~ '^[a-z][a-z0-9_]{2,62}$'),
  subject_id    uuid,
  -- Denormalised, because the question is always "who saw this resident's record".
  -- Deliberately not a foreign key: the trail has to outlive the record it describes.
  -- Audit is kept for years; a care record is deleted when the facility's retention
  -- window closes, and a reference here would make that deletion impossible. After
  -- retention this column names a resident who no longer exists, which is the correct
  -- answer rather than a dangling one.
  resident_id   uuid,

  request_id    text,        -- ties a row to one HTTP request across services
  ip_hash       text,        -- hashed, not stored raw
  user_agent    text,

  -- Never the record itself. What changed, not what it said.
  detail        jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX ON audit_events (resident_id, occurred_at DESC);
CREATE INDEX ON audit_events (actor_user_id, occurred_at DESC);
CREATE INDEX ON audit_events (facility_id, occurred_at DESC);

COMMENT ON COLUMN audit_events.detail IS
  'Field names and identifiers only. No PHI: an audit log that quotes the record it is
   protecting has become a second copy of it.';


-- ════════════════════════════════════════════════════════════════════ retention
--
-- The rule is facility policy, not a developer decision, so it is data. Enforcement is a
-- scheduled job that reads this table; the job removes the GCS object and stamps
-- media_objects.deleted_at rather than hiding the row.

CREATE TABLE retention_policies (
  facility_id            uuid PRIMARY KEY REFERENCES facilities(id) ON DELETE CASCADE,
  care_record_days       integer NOT NULL,   -- after a resident departs
  media_days             integer NOT NULL,
  audit_days             integer NOT NULL,

  -- What the care-record number rests on. A facility that decides a number without being
  -- able to name the statute or the policy behind it has decided a number, and a licensed
  -- long-term-care facility is subject to a state minimum measured in years.
  care_record_basis      text NOT NULL,

  updated_by             uuid REFERENCES users(id),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  CHECK (care_record_days > 0 AND media_days > 0),
  CHECK (length(btrim(care_record_basis)) > 0),

  -- The floor the rule sets, and the only one of the three that is not the facility's to
  -- choose. The audit trail is the accounting of disclosures a facility owes a resident
  -- for six years, and the record of security activity a business associate must retain
  -- for the same. A facility that set thirty days would have had both destroyed on
  -- schedule by a job working exactly as designed.
  CONSTRAINT audit_window_is_at_least_six_years CHECK (audit_days >= 2190)
);

COMMENT ON TABLE retention_policies IS
  'Deliberately per facility. Two buildings under different operators can be subject to
   different rules, and the code should follow whatever the facility says rather than
   carry a default nobody agreed to.';


-- ════════════════════════════════════════════════════════════════════ what may change
--
-- A care record is amended by adding: a correction is a new row, and the original is
-- stamped superseded_at. That is the design, and for a while it was only the design.
--
-- The policy that was supposed to enforce it is FOR UPDATE ... USING, which restricts
-- which rows may be updated and says nothing about which columns. So an assigned caregiver
-- could replace a note, reassign its authorship, and leave superseded_at null - and the
-- audit trail, which records column names and never their contents precisely so that it
-- does not become a second copy of the record, could say only that note and filed_by had
-- changed. The original was gone from the database and from the trail alike.
--
-- Found by an independent review of this model, reproduced, and fixed here rather than in
-- a policy: a policy can restrict rows, and this is a statement about columns.

CREATE OR REPLACE FUNCTION reject_record_rewrite() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
DECLARE
  allowed text[] := TG_ARGV::text[];
  changed text[];
BEGIN
  SELECT array_agg(k ORDER BY k) INTO changed
  FROM jsonb_object_keys(to_jsonb(NEW)) k
  WHERE to_jsonb(NEW) -> k IS DISTINCT FROM to_jsonb(OLD) -> k
    AND NOT (k = ANY(allowed));

  IF changed IS NOT NULL THEN
    RAISE EXCEPTION '%: % may not change on a row that already exists',
      TG_TABLE_NAME, array_to_string(changed, ', ')
      USING ERRCODE = 'check_violation',
            HINT = 'Column names only - the values are deliberately not repeated here, for the same reason the audit trail does not repeat them.';
  END IF;
  RETURN NEW;
END; $$;

COMMENT ON FUNCTION reject_record_rewrite() IS
  'Takes the columns that may change as trigger arguments. Everything else on the row is
   what it was when it was filed. The message names the columns and never their contents,
   so a refusal is safe to log - the same rule reject_unhashed_credential follows.';


-- A filed day: only the stamp that retires it, and the timestamp that records when.
CREATE TRIGGER care_days_are_amended_not_rewritten
  BEFORE UPDATE ON care_days
  FOR EACH ROW EXECUTE FUNCTION reject_record_rewrite('superseded_at', 'updated_at');

-- And the stamp is one way. Un-superseding a row would make a correction disappear and
-- the original current again, which is a rewrite by two statements instead of one.
CREATE OR REPLACE FUNCTION reject_unsupersede() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
BEGIN
  IF OLD.superseded_at IS NOT NULL AND NEW.superseded_at IS NULL THEN
    RAISE EXCEPTION 'a superseded care day cannot be made current again'
      USING ERRCODE = 'check_violation',
            HINT = 'The correction that superseded it is still there. Making this row current would leave two.';
  END IF;
  RETURN NEW;
END; $$;

CREATE TRIGGER care_days_supersede_is_one_way
  BEFORE UPDATE ON care_days
  FOR EACH ROW EXECUTE FUNCTION reject_unsupersede();

-- A resident does not move buildings by an UPDATE. A transfer is a departure and an
-- admission, and the two facilities' records stay separate - which is also what stops a
-- manager pulling a resident into their own facility to read them.
CREATE TRIGGER residents_do_not_change_facility
  BEFORE UPDATE ON residents
  FOR EACH ROW EXECUTE FUNCTION reject_record_rewrite(
    'display_name', 'external_source', 'external_patient_id',
    'baseline_mood', 'baseline_appetite', 'baseline_sleep',
    'admitted_on', 'departed_on', 'updated_at');

-- Family access is withdrawn by revoking the row, never by editing who it was for.
CREATE TRIGGER contacts_are_revoked_not_rewritten
  BEFORE UPDATE ON resident_contacts
  FOR EACH ROW EXECUTE FUNCTION reject_record_rewrite(
    'state', 'revoked_by', 'revoked_at', 'granted_by', 'granted_at', 'updated_at');

