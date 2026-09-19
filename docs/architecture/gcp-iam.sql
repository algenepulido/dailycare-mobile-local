-- GCP IAM for M2.
--
-- Trevor asked for the exact roles rather than Owner, so this is the list and the reasoning
-- where the reasoning isn't obvious. Two things worth saying before the table:
--
-- Most of the privilege that matters isn't in IAM. cloudsql.client gets you a connection;
-- what you can do once you're connected is decided by roles.sql and grants.sql, and that's
-- where least privilege actually lives for this system. IAM is the outer door.
--
-- And only the products on Google's HIPAA Included Products list are covered by the BAA.
-- Everything below is on it as of writing. Worth re-checking when we add a service --
-- Google moves things onto that list more often than off it, but not never.

CREATE TYPE iam_principal_kind AS ENUM ('person', 'service_account');
CREATE TYPE iam_scope_kind AS ENUM
  ('project', 'secret', 'bucket', 'service_account', 'repository');

CREATE TABLE gcp_iam (
  principal    text NOT NULL,
  kind         iam_principal_kind NOT NULL,
  role         text NOT NULL,
  scope_kind   iam_scope_kind NOT NULL,
  scope_refs   text[],                 -- null for project scope
  why          text,
  temporary    boolean NOT NULL DEFAULT false,
  PRIMARY KEY (principal, role, scope_kind),
  CHECK ((scope_kind = 'project') = (scope_refs IS NULL))
);

COMMENT ON COLUMN gcp_iam.temporary IS
  'True means remove it when M2 is done. Nobody removes these unless they are written down.';


-- ── people ─────────────────────────────────────────────────────────────────────
-- One person, during M2. Deploy, connect, read logs. Not create, not delete, not IAM.

INSERT INTO gcp_iam (principal, kind, role, scope_kind, scope_refs, why, temporary) VALUES
('algene','person','roles/run.developer','project',NULL,
 'Deploy revisions. Does not cover setting which service account a revision runs as -- that is the next one.',true),

('algene','person','roles/iam.serviceAccountUser','service_account',
 ARRAY['dailycare-api','dailycare-retention','dailycare-integration','dailycare-backup'],
 'Needed to deploy a revision that runs as one of these. On the four SAs and not the project: at project level it is impersonation of anything created later.',true),

('algene','person','roles/cloudsql.client','project',NULL,NULL,true),
('algene','person','roles/cloudsql.instanceUser','project',NULL,
 'IAM database auth, so there is no password for a person to lose.',true),

('algene','person','roles/secretmanager.secretAccessor','secret',
 ARRAY['dailycare-db-password','dailycare-jwt-key','dailycare-twilio','dailycare-pointclickcare'],
 'Read a value. Not secretVersionAdder, not admin. Rotating a secret is an operator act and should not be doable by the account that writes the code.',true),

('algene','person','roles/artifactregistry.writer','repository',ARRAY['dailycare'],NULL,true),
('algene','person','roles/logging.viewer','project',NULL,NULL,true),
('algene','person','roles/monitoring.viewer','project',NULL,NULL,true),
('algene','person','roles/storage.objectAdmin','bucket',ARRAY['dailycare-media'],
 'The bucket, not the project.',true);

-- Not asked for, in case the absence looks like an oversight:
--   roles/owner, roles/editor                  no
--   roles/cloudsql.admin                       instance creation is yours
--   roles/resourcemanager.projectIamAdmin      granting roles is yours
--   roles/secretmanager.admin                  see above
--   roles/storage.admin                        bucket creation and lifecycle are yours
--
-- One open question. Applying the schema needs a Postgres role that can CREATE ROLE, once,
-- for roles.sql. That is a database privilege and not an IAM one, so it is not in the list
-- above. Either you run roles.sql yourself and I get an ordinary user afterwards, or I get
-- the postgres user for the first migration and you rotate it after. Second is less work
-- for you, first is tighter. Your call -- I am fine either way.


-- ── service accounts ───────────────────────────────────────────────────────────
-- Four, because they do four different things, and one compromise should not be four.

INSERT INTO gcp_iam (principal, kind, role, scope_kind, scope_refs, why) VALUES
('dailycare-api','service_account','roles/cloudsql.client','project',NULL,NULL),
('dailycare-api','service_account','roles/secretmanager.secretAccessor','secret',
 ARRAY['dailycare-db-password','dailycare-jwt-key','dailycare-twilio'],
 'Three named secrets, not the project. Otherwise the API can read the integration credential, and that credential is the only thing stopping a stolen session writing a medication event attributed to the clinical system.'),
-- Not objectAdmin: it includes objects.delete, and the whole point of the retention
-- handshake is that the API never removes an object. Caught by the check below, which is
-- the second time that role has been more than it looked.
('dailycare-api','service_account','roles/storage.objectCreator','bucket',ARRAY['dailycare-media'],NULL),
('dailycare-api','service_account','roles/storage.objectViewer','bucket',ARRAY['dailycare-media'],NULL),
('dailycare-api','service_account','roles/iam.serviceAccountTokenCreator','service_account',
 ARRAY['dailycare-api'],
 'Signs the photo URLs. On itself. At project level this role is impersonation of everything.'),
('dailycare-api','service_account','roles/logging.logWriter','project',NULL,NULL),

('dailycare-retention','service_account','roles/cloudsql.client','project',NULL,NULL),
('dailycare-retention','service_account','roles/storage.objectAdmin','bucket',ARRAY['dailycare-media'],
 'objectAdmin here on purpose -- it is the delete half of the handshake, and this is the only principal that gets it.'),
('dailycare-retention','service_account','roles/logging.logWriter','project',NULL,NULL),

('dailycare-integration','service_account','roles/cloudsql.client','project',NULL,NULL),
('dailycare-integration','service_account','roles/secretmanager.secretAccessor','secret',
 ARRAY['dailycare-pointclickcare'],'One secret.'),
('dailycare-integration','service_account','roles/logging.logWriter','project',NULL,NULL),

('dailycare-backup','service_account','roles/cloudsql.client','project',NULL,NULL),
('dailycare-backup','service_account','roles/storage.objectAdmin','bucket',ARRAY['dailycare-backup'],NULL),
('dailycare-backup','service_account','roles/logging.logWriter','project',NULL,NULL),

('github-deploy','service_account','roles/artifactregistry.writer','repository',ARRAY['dailycare'],NULL),
('github-deploy','service_account','roles/run.developer','project',NULL,NULL),
('github-deploy','service_account','roles/iam.serviceAccountUser','service_account',
 ARRAY['dailycare-api','dailycare-retention','dailycare-integration','dailycare-backup'],
 'Deploys as them. No secret access and no database reach. CI needs neither, and has been the way into plenty of systems that gave it both.');


-- ── what this doesn't cover ────────────────────────────────────────────────────

CREATE VIEW iam_yours AS
SELECT * FROM (VALUES
  ('project creation and the billing account'),
  ('the BAA, and re-checking the Included Products list when we add a service'),
  ('creating the Cloud SQL instance, the buckets and the service accounts'),
  ('granting everything in gcp_iam'),
  ('CMEK, if you decide you want it -- see encryption-and-secrets.sql for why we said no for now'),
  ('the VPC and whether Cloud SQL gets a private address only')
) AS t(item);


-- ── the commands ───────────────────────────────────────────────────────────────
-- Run the output. Project-scoped ones are exact; the resource-scoped ones need the
-- resource name filling in, which is why they come out commented.

CREATE OR REPLACE FUNCTION iam_member(p text, k iam_principal_kind) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, public AS $$
  SELECT CASE WHEN k = 'person'
              THEN 'user:$' || upper(replace(p,'-','_')) || '_EMAIL'
              ELSE 'serviceAccount:' || p || '@$PROJECT.iam.gserviceaccount.com' END
$$;

CREATE VIEW iam_grant_commands AS
SELECT g.principal, g.temporary,
  CASE g.scope_kind
    WHEN 'project' THEN format(
      'gcloud projects add-iam-policy-binding $PROJECT --member=%s --role=%s',
      iam_member(g.principal, g.kind), g.role)
    WHEN 'secret' THEN format(
      'gcloud secrets add-iam-policy-binding %s --project=$PROJECT --member=%s --role=%s',
      r, iam_member(g.principal, g.kind), g.role)
    WHEN 'bucket' THEN format(
      'gcloud storage buckets add-iam-policy-binding gs://%s-$ENV --member=%s --role=%s',
      r, iam_member(g.principal, g.kind), g.role)
    WHEN 'service_account' THEN format(
      'gcloud iam service-accounts add-iam-policy-binding %s@$PROJECT.iam.gserviceaccount.com --member=%s --role=%s',
      r, iam_member(g.principal, g.kind), g.role)
    WHEN 'repository' THEN format(
      'gcloud artifacts repositories add-iam-policy-binding %s --location=$REGION --member=%s --role=%s',
      r, iam_member(g.principal, g.kind), g.role)
  END AS command
FROM gcp_iam g
LEFT JOIN LATERAL unnest(coalesce(g.scope_refs, ARRAY[NULL::text])) AS r ON true
ORDER BY g.kind, g.principal, g.role, r;

COMMENT ON VIEW iam_grant_commands IS
  'Set PROJECT, REGION, ENV and ALGENE_EMAIL and run the output. Every line is a real
   command -- the first version of this emitted the resource-scoped ones as comments for
   somebody else to write, which is half a job.';

CREATE VIEW iam_temporary AS
SELECT principal, role, scope_kind, scope_refs FROM gcp_iam WHERE temporary;

COMMENT ON VIEW iam_temporary IS
  'Remove when M2 closes. Here so that "temporary" means something.';
