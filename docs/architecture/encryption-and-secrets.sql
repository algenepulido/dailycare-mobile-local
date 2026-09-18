-- Encryption and secrets
--
-- Applied after data-classification.sql.
--
-- Most of what a package says about encryption is true of any managed database and is
-- therefore not very interesting: it is encrypted at rest because the platform encrypts
-- everything at rest, and in transit because the connection is TLS. Recording that is
-- necessary and says almost nothing about whether this system is careful.
--
-- The parts that do say something are three.
--
-- Where a secret lives, as a table with a constraint, because the two places a secret must
-- never be are the two places it always ends up: the repository, and an environment
-- variable baked into an image. Neither is a policy failure when it happens - it is a
-- Tuesday - so they are refused rows rather than review findings.
--
-- What is kept instead of the secret. A password is an Argon2id digest and a session token
-- a SHA-256 one, and the columns refuse anything else; that is in schema.sql beside the
-- columns it constrains, and it is the difference between a claim and a property.
--
-- And who can make the data unreadable. Customer-managed keys are usually discussed as
-- protection against the platform reading the data. The more likely incident is losing the
-- key and being unable to read it yourself, which is why the decision is recorded here with
-- that written down rather than treated as obviously better.


CREATE TYPE secret_store AS ENUM (
  'secret_manager',     -- Google Secret Manager, read at boot by the service identity
  'eas_credentials',    -- signing keys, held by the build service
  'database_digest',    -- not stored at all: only a digest of it is
  'platform_managed',   -- the platform holds it and never hands it over
  'repository',         -- never
  'image_environment'   -- never
);

CREATE TABLE secrets_inventory (
  id              text PRIMARY KEY,
  what            text NOT NULL,
  store           secret_store NOT NULL,
  rotation_days   integer,
  last_rotated_on date,
  who_may_read    text NOT NULL,
  note            text,
  reviewed_on     date NOT NULL,

  CONSTRAINT secret_is_not_in_the_two_places_it_always_ends_up
    CHECK (store NOT IN ('repository', 'image_environment')),

  -- A secret that is never rotated is a decision, and one that has to be argued for in the
  -- note rather than left as a null nobody notices.
  CONSTRAINT rotation_is_stated
    CHECK (rotation_days IS NOT NULL OR note IS NOT NULL),
  CHECK (rotation_days IS NULL OR rotation_days > 0)
);

COMMENT ON CONSTRAINT secret_is_not_in_the_two_places_it_always_ends_up ON secrets_inventory IS
  'A checked-in credential and an environment variable baked into an image are not policy
   failures. They are Tuesdays. Making them unrepresentable is worth more than a paragraph
   asking people not to.';


INSERT INTO secrets_inventory (id, what, store, rotation_days, last_rotated_on,
                               who_may_read, note, reviewed_on) VALUES
('db_password', 'The API''s PostgreSQL password', 'secret_manager', 90, NULL,
 'The API service identity, at boot. Not a person.',
 'Read through the platform''s secret API rather than injected, so a rotation does not need a redeploy.',
 DATE '2026-09-15'),

('jwt_signing_key', 'The key access tokens are signed with', 'secret_manager', 90, NULL,
 'The API service identity.',
 'Rotated with an overlap: the previous key stays accepted for the life of the longest access token, which is fifteen minutes.',
 DATE '2026-09-15'),

('media_signing_key', 'The key photograph URLs are signed with', 'platform_managed', NULL, NULL,
 'Nobody. The platform mints the signature.',
 'Never held by the application, so there is nothing to rotate and nothing to leak. The control that matters for photographs is that the URL is minted per request after the policy has admitted the caller.',
 DATE '2026-09-15'),

('twilio_token', 'Credentials for sending an invitation', 'secret_manager', 180, NULL,
 'The API service identity.',
 NULL, DATE '2026-09-15'),

('pointclickcare_client', 'Credentials for the clinical-system feed', 'secret_manager', 180, NULL,
 'The integration job''s identity, which is not the API''s.',
 'Separate identity on purpose: a compromised API session cannot reach the feed''s credentials, which is what stops it writing a medication event attributed to a clinical system.',
 DATE '2026-09-15'),

('ios_signing', 'The iOS distribution certificate and provisioning profile', 'eas_credentials',
 365, NULL, 'The build service, and whoever holds the store account.',
 'Held by the build service rather than on a laptop. Expiry is the practical risk, not theft: a certificate that lapses stops releases.',
 DATE '2026-09-15'),

('android_keystore', 'The Android upload key', 'eas_credentials', NULL, NULL,
 'The build service.',
 'Deliberately never rotated. Losing it means the application can no longer be updated under the same identity, which is a worse outcome than the one rotation would protect against.',
 DATE '2026-09-15'),

('user_passwords', 'What a person types to sign in', 'database_digest', NULL, NULL,
 'Nobody, including us.',
 'Not stored. The column holds an Argon2id digest and the database refuses anything else, so this is a property of the table rather than of the handler that last wrote to it.',
 DATE '2026-09-15'),

('session_tokens', 'Refresh tokens and invitation links', 'database_digest', NULL, NULL,
 'Nobody after the moment they are issued.',
 'Not stored. The columns hold a SHA-256 digest and refuse a raw token, so a stolen dump of those tables cannot be replayed as a session.',
 DATE '2026-09-15');


-- ════════════════════════════════════════════════════════════════════ encryption

CREATE TYPE control_state AS ENUM ('in_effect', 'planned', 'declined');

CREATE TABLE encryption_controls (
  id             text PRIMARY KEY,
  covers         text NOT NULL,
  mechanism      text NOT NULL,
  key_management text NOT NULL,
  state          control_state NOT NULL,
  note           text,
  reviewed_on    date NOT NULL
);

INSERT INTO encryption_controls (id, covers, mechanism, key_management, state, note, reviewed_on) VALUES
('at_rest_database', 'Every table, including the audit trail',
 'Platform encryption on the Cloud SQL instance',
 'Platform-managed keys', 'planned',
 'Nothing here is optional or configurable; it is what the instance does. Marked planned only because no instance exists yet.',
 DATE '2026-09-15'),

('at_rest_storage', 'Photographs', 'Platform encryption on the bucket',
 'Platform-managed keys', 'planned', NULL, DATE '2026-09-15'),

('at_rest_backups', 'Snapshots and point-in-time recovery',
 'Inherited from the instance', 'Platform-managed keys', 'planned',
 'A backup is not a weaker copy of the database. Worth saying explicitly because it is the assumption most often wrong elsewhere.',
 DATE '2026-09-15'),

('in_transit_client', 'Device to API', 'TLS 1.2 or better, certificate pinning not used',
 'Platform-managed certificate', 'planned',
 'Pinning was considered and declined: it breaks a client that has not been updated when a certificate rotates, and the failure mode is a caregiver who cannot file a day.',
 DATE '2026-09-15'),

('in_transit_database', 'API to PostgreSQL', 'TLS over a private address',
 'Platform-managed', 'planned',
 'The instance has no public address, so this is not the only thing standing between the database and the internet.',
 DATE '2026-09-15'),

('customer_managed_keys', 'Database and storage at rest',
 'Cloud KMS keys held by InkTree rather than the platform',
 'InkTree, with the responsibility that comes with it', 'declined',
 'Declined for now, and the reason is worth recording. The threat it addresses is the platform reading the data, which the agreement already addresses contractually. The threat it creates is losing the key, after which nobody reads the data - including the facility whose records they are. Revisit if a facility asks for it.',
 DATE '2026-09-15'),

('at_rest_device', 'A care day on a caregiver''s phone, and a photograph waiting to upload',
 'Credentials in the platform keychain; care data not persisted, or persisted encrypted; photographs staged in the cache directory and purged once the upload is acknowledged',
 'Platform keystore, per device', 'planned',
 'The fourth place a record rests, and the only one that leaves the building. The Milestone 1 client keeps its state in AsyncStorage, which is not encrypted, and stages photographs on the file system - which is correct for synthetic data and is the whole design of that milestone. The moment it holds a real care day it is a store, on a device that goes home in a pocket. revoke_all_sessions() is the lost-phone control for the server; this is the one for what is already on the phone. Milestone 3.',
 DATE '2026-09-18'),

('signed_url_lifetime', 'Links to photographs',
 'Signed URLs minted per request with a short expiry, currently fifteen minutes',
 'Platform-managed signing key; the application never holds it', 'planned',
 'Recorded as a control because it is the only one acting on a link once it exists. The row in media_objects gates the minting; it cannot reach a URL already handed out, which works until it expires whatever happens to the grant. Three places in this package previously said otherwise. If a withdrawal has to take effect immediately, the alternative is an authenticated proxy - a request per image through the API, paying a round trip for revocation that is measured in minutes rather than instant.',
 DATE '2026-09-17'),

('field_level_encryption', 'Care notes and resident names',
 'Application-level encryption before the row is written',
 'Would need a key the database cannot read', 'declined',
 'Declined. It would defeat the access model rather than strengthen it: row-level security cannot filter on a column it cannot read, search stops working, and the audit trail would record access to something nobody can interpret. The protection it offers over platform encryption is against somebody who already has the database, who at that point also has the application that decrypts it.',
 DATE '2026-09-15');


-- ════════════════════════════════════════════════════════════════════ the questions

CREATE VIEW secrets_overdue AS
SELECT id, what, rotation_days, last_rotated_on,
       current_date - last_rotated_on AS days_since
FROM secrets_inventory
WHERE rotation_days IS NOT NULL
  AND last_rotated_on IS NOT NULL
  AND last_rotated_on + rotation_days < current_date;

COMMENT ON VIEW secrets_overdue IS
  'Must be empty. Empty today for the uninteresting reason that nothing has been created
   yet, which is why last_rotated_on is null everywhere and why that is not treated as
   overdue - a secret that does not exist is not a secret nobody rotated.';

CREATE VIEW secrets_never_rotated AS
SELECT id, what, store, note FROM secrets_inventory
WHERE rotation_days IS NULL;

COMMENT ON VIEW secrets_never_rotated IS
  'Expected to have rows, and each one carries the argument for it. The Android upload key
   is the clearest: losing it is worse than the risk rotating it would reduce.';

CREATE VIEW encryption_not_in_effect AS
SELECT id, covers, state FROM encryption_controls WHERE state <> 'in_effect';

CREATE VIEW phi_stores_without_encryption AS
-- Every place a resident's record rests, against the controls that claim to cover it.
-- The device is the fourth, and was missing: the inventory knew about the database, the
-- bucket and the backups, and not about the phone that goes home in a pocket.
SELECT s.place
FROM (VALUES ('database'), ('storage'), ('backups'), ('device')) AS s(place)
WHERE NOT EXISTS (
  SELECT 1 FROM encryption_controls c
  WHERE c.id LIKE 'at_rest_%' AND c.id LIKE ('%' || s.place)
    AND c.state <> 'declined');

COMMENT ON VIEW phi_stores_without_encryption IS
  'Must be empty. Four places hold a resident''s record at rest and each needs a control
   that is not declined. It was three until an independent review pointed at the phone.';

-- Counting a plan as coverage is how a package tells itself it is finished. Separate view,
-- expected to have rows today and empty before the first real record - the way
-- never_drilled is.
CREATE VIEW phi_stores_encryption_planned AS
SELECT c.id, c.covers, c.state
FROM encryption_controls c
WHERE c.id LIKE 'at_rest_%' AND c.state = 'planned';

COMMENT ON VIEW phi_stores_encryption_planned IS
  'Expected to have rows while nothing is deployed. The view above asks whether a place has
   a control at all; this one asks whether the control exists yet, and the difference is
   the difference between a plan and a thing.';

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dailycare_app') THEN
    REVOKE ALL ON secrets_inventory, encryption_controls FROM dailycare_app;
  END IF;
END $$;

-- ════════════════════════════════════════════════════════════════════ classification
--
-- A table added to this schema is a table the PHI inventory has to have an answer for,
-- and "operational" is an answer that has to be written down rather than inferred from
-- nobody having said otherwise. unclassified_columns is checked by the suites.

-- secrets_inventory: Where a secret lives and who may read it. Never the secret.
INSERT INTO data_classification (table_name, column_name, class, note) VALUES
 ('secrets_inventory','id','operational',NULL),
 ('secrets_inventory','last_rotated_on','operational',NULL),
 ('secrets_inventory','note','operational',NULL),
 ('secrets_inventory','reviewed_on','operational',NULL),
 ('secrets_inventory','rotation_days','operational',NULL),
 ('secrets_inventory','store','operational',NULL),
 ('secrets_inventory','what','operational',NULL),
 ('secrets_inventory','who_may_read','operational',NULL);

-- encryption_controls: What is encrypted and how keys are held.
INSERT INTO data_classification (table_name, column_name, class, note) VALUES
 ('encryption_controls','covers','operational',NULL),
 ('encryption_controls','id','operational',NULL),
 ('encryption_controls','key_management','operational',NULL),
 ('encryption_controls','mechanism','operational',NULL),
 ('encryption_controls','note','operational',NULL),
 ('encryption_controls','reviewed_on','operational',NULL),
 ('encryption_controls','state','operational',NULL);

