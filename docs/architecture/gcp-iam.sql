-- GCP IAM.
--
-- This started as a proposal - Trevor asked for the exact roles rather than Owner, so it
-- was a list of what to grant. It is not a proposal any more. The three projects were
-- created on 10 September, dev and staging were provisioned before anybody here saw this
-- file, and docs/gcp-as-built.md is Inktree's handover describing what is actually there.
-- So this is now a claim about what should be true of a real policy, which is a different
-- kind of thing and has to be checked differently.
--
-- The check that matters is gcp_iam_drift, at the bottom. Until it runs against a real
-- policy dump, everything here is still only a list that agrees with itself - which was
-- the fair criticism Inktree made of the first version, and they were right: the "nothing
-- broad" check read this table rather than live IAM, so it would have passed while dev
-- held five roles that match it.
--
-- Two things that have not changed:
--
-- Most of the privilege that matters isn't in IAM. cloudsql.client gets you a connection;
-- what you can do once connected is decided by roles.sql and grants.sql. IAM is the outer
-- door.
--
-- And only the products on Google's HIPAA Included Products list are covered by the BAA.
-- Worth re-checking when a service is added - Google moves things onto that list more
-- often than off it, but not never.

CREATE TYPE gcp_environment AS ENUM ('dev', 'staging', 'prod');
-- Three, because a federated principal set is neither of the other two. It is not an
-- identity at all: it is a rule that says which external tokens may act as one, and
-- checks written for accounts ask the wrong questions about it - it has no environment
-- prefix in its name and no counterpart in the other project.
CREATE TYPE iam_principal_kind AS ENUM ('person', 'service_account', 'federated');
CREATE TYPE iam_scope_kind AS ENUM
  ('project', 'secret', 'bucket', 'service_account', 'repository');


CREATE TABLE gcp_projects (
  environment    gcp_environment PRIMARY KEY,
  project_id     text NOT NULL UNIQUE,
  project_number text NOT NULL UNIQUE,
  region         text NOT NULL,
  note           text
);

INSERT INTO gcp_projects VALUES
('dev','inktree-dailycare-dev','144065101336','us-central1',
 'Synthetic data only. Self-serve: named admin roles, so a bucket does not need a ticket.'),
('staging','inktree-dailycare-staging','1020149956206','us-central1',
 'Synthetic data only. Deploy and read, nothing that creates.'),
('prod','inktree-dailycare-prod','692675456098','us-central1',
 'Guardrails and nothing else until the M6 gate. No service accounts, no registry, no access for us.');

COMMENT ON TABLE gcp_projects IS
  'Created 10 September 2026, BAA accepted the same day. Separate from the Inktree platform
   projects - no shared service account, bucket, log sink or IAM - which is the project-level
   separation the open-questions list asked for.';


-- ── the bindings ───────────────────────────────────────────────────────────────

CREATE TABLE gcp_iam (
  environment  gcp_environment NOT NULL REFERENCES gcp_projects(environment),
  principal    text NOT NULL,
  kind         iam_principal_kind NOT NULL,
  role         text NOT NULL,
  scope_kind   iam_scope_kind NOT NULL,
  scope_refs   text[],                 -- null for project scope
  why          text,
  temporary    boolean NOT NULL DEFAULT false,

  -- Staging carries a Google-enforced IAM condition rather than a note in a document. It
  -- is not a deadline; it fails closed if M2 runs long and nobody remembers.
  expires_on   date,

  PRIMARY KEY (environment, principal, role, scope_kind),
  CHECK ((scope_kind = 'project') = (scope_refs IS NULL))
);

COMMENT ON COLUMN gcp_iam.expires_on IS
  'From the IAM condition on the binding. Enforced by Google, not by anybody remembering.';


-- ── the person ─────────────────────────────────────────────────────────────────
--
-- One account, jenith.dev1202@gmail.com, and every binding is on that address. Worth being
-- exact about it because a binding on the wrong address grants nothing and fails in a way
-- indistinguishable from a policy bug.
--
-- The address also becomes the database login name under IAM database authentication, so it
-- ends up inside the instance and in its audit trail rather than only in the IAM policy.

-- Dev: self-serve. Trevor's reasoning is that dev holds synthetic data only and has no path
-- to production, so waiting on someone else for every bucket costs more than it protects.
-- That is a sound argument for dev specifically, and it is only sound while the first half
-- stays true - which is why the one rule in the handover is the rule it is, and why
-- environments.sql refuses a connection to a copy that has not been scrubbed.
--
-- The handover names these four explicitly and describes the rest by service - Cloud Run,
-- VPC, Service Networking, Cloud Scheduler, Service Usage. Those are deliberately not
-- guessed at here. gcp_iam_drift will report them as observed-and-not-declared the first
-- time it sees a real policy, and then they can be written down from what is actually
-- granted rather than from what a document says in prose.
-- These twenty are what the policy actually grants, read with
-- ./load-iam-policy.sh inktree-dailycare-dev dev rather than transcribed from prose. The
-- handover described most of them by service - "named admin roles across Cloud Run, Cloud
-- SQL, Storage, Secret Manager, Artifact Registry, VPC, Service Networking, Cloud
-- Scheduler, and Service Usage" - and guessing the exact strings from that would have
-- produced a list that agreed with itself and not with the project.
--
-- Three are marked below as worth a question rather than silently written down.
INSERT INTO gcp_iam (environment, principal, kind, role, scope_kind, scope_refs, why, temporary) VALUES
('dev','jenith.dev1202@gmail.com','person','roles/cloudsql.admin','project',NULL,
 'Creates the instance. Broader than the proposal asked for, on purpose: dev holds synthetic data only and has no path to production, so waiting on somebody for every resource costs more than it protects.',false),
('dev','jenith.dev1202@gmail.com','person','roles/storage.admin','project',NULL,
 'Creates the media and backup buckets and sets the object roles on them.',false),
('dev','jenith.dev1202@gmail.com','person','roles/secretmanager.admin','project',NULL,
 'Adds secret values in dev. In staging this is read-only and Inktree sets them.',false),
('dev','jenith.dev1202@gmail.com','person','roles/artifactregistry.admin','project',NULL,NULL,false),
('dev','jenith.dev1202@gmail.com','person','roles/run.admin','project',NULL,NULL,false),
('dev','jenith.dev1202@gmail.com','person','roles/cloudscheduler.admin','project',NULL,
 'The retention job runs on a schedule.',false),
('dev','jenith.dev1202@gmail.com','person','roles/compute.networkAdmin','project',NULL,
 'The VPC the instance sits behind, since sql.restrictPublicIp leaves no other way to reach it.',false),
('dev','jenith.dev1202@gmail.com','person','roles/servicenetworking.networksAdmin','project',NULL,
 'Private services access, which is what a private Cloud SQL address needs.',false),
('dev','jenith.dev1202@gmail.com','person','roles/vpcaccess.admin','project',NULL,
 'The connector Cloud Run reaches the instance through.',false),
('dev','jenith.dev1202@gmail.com','person','roles/serviceusage.serviceUsageAdmin','project',NULL,
 'Turning an API on. Enabling one is the first step of most of the above.',false),
('dev','jenith.dev1202@gmail.com','person','roles/cloudsql.client','project',NULL,NULL,false),
('dev','jenith.dev1202@gmail.com','person','roles/cloudsql.instanceUser','project',NULL,
 'IAM database auth, so there is no password for a person to lose.',false),
('dev','jenith.dev1202@gmail.com','person','roles/iam.serviceAccountUser','project',NULL,
 'Deploying a revision that runs as one of the four.',false),
('dev','jenith.dev1202@gmail.com','person','roles/logging.viewer','project',NULL,NULL,false),
('dev','jenith.dev1202@gmail.com','person','roles/logging.configWriter','project',NULL,
 'Log sinks and retention.',false),
('dev','jenith.dev1202@gmail.com','person','roles/monitoring.editor','project',NULL,NULL,false),
('dev','jenith.dev1202@gmail.com','person','roles/orgpolicy.policyViewer','project',NULL,
 'Read the four guardrails. Viewing them, not changing them.',false),

-- The three worth a question. All read as ordinary parts of a self-serve sandbox and all
-- three are wider than the sentence in the handover that justified the sandbox.
('dev','jenith.dev1202@gmail.com','person','roles/viewer','project',NULL,
 'A basic role. The handover says owner and editor are deliberately absent; viewer is the third of the three and it reads everything in the project, including anything added later. Probably wanted broad read and this was the quick way to it. Worth asking whether it can come off, since the named roles above already carry the reads that are used.',false),
('dev','jenith.dev1202@gmail.com','person','roles/iam.serviceAccountAdmin','project',NULL,
 'Creates and deletes service accounts. Not needed to use the four that exist.',false),
('dev','jenith.dev1202@gmail.com','person','roles/iam.serviceAccountTokenCreator','project',NULL,
 'At project level this is impersonation of every service account in the project. The handover makes exactly this argument about the api account, where it is scoped to the account rather than the project - so the same reasoning points at this one. Impersonation is also how deploys work here, since the no-keys policy leaves no alternative, so the answer may be to scope it to the four rather than remove it.',false);

-- Theirs, recorded so the policy reads the same as this file rather than nearly the same.
INSERT INTO gcp_iam (environment, principal, kind, role, scope_kind, scope_refs, why) VALUES
('dev','production@inktree.ai','person','roles/owner','project',NULL,
 'Inktree. Ours to record, not ours to hold.');

-- Staging: exactly the list from the handover, every binding expiring on the same day.
INSERT INTO gcp_iam (environment, principal, kind, role, scope_kind, scope_refs, why, temporary, expires_on) VALUES
('staging','jenith.dev1202@gmail.com','person','roles/run.developer','project',NULL,NULL,true,DATE '2026-12-20'),
('staging','jenith.dev1202@gmail.com','person','roles/cloudsql.client','project',NULL,NULL,true,DATE '2026-12-20'),
('staging','jenith.dev1202@gmail.com','person','roles/cloudsql.instanceUser','project',NULL,
 'IAM database auth, so there is no password for a person to lose.',true,DATE '2026-12-20'),
('staging','jenith.dev1202@gmail.com','person','roles/artifactregistry.writer','project',NULL,NULL,true,DATE '2026-12-20'),
('staging','jenith.dev1202@gmail.com','person','roles/logging.viewer','project',NULL,NULL,true,DATE '2026-12-20'),
('staging','jenith.dev1202@gmail.com','person','roles/monitoring.viewer','project',NULL,NULL,true,DATE '2026-12-20'),
('staging','jenith.dev1202@gmail.com','person','roles/secretmanager.secretAccessor','secret',
 ARRAY['db_password','jwt_signing_key','twilio_token','pointclickcare_client'],
 'Read a value. Not secretVersionAdder, not admin: rotating a secret is an operator act and should not be doable by the account that writes the code.',true,DATE '2026-12-20'),
('staging','jenith.dev1202@gmail.com','person','roles/iam.serviceAccountUser','service_account',
 ARRAY['dc-stg-api'],
 'gcloud run deploy --service-account fails without actAs. On the api account only, so a deploy cannot run as retention, integration or backup.',true,DATE '2026-12-20');


-- ── the four identities ────────────────────────────────────────────────────────
--
-- One per Postgres role in roles.sql, so a leaked credential is not all four. The names are
-- Inktree's: dc-dev-api rather than dailycare-api. The first version of this file invented
-- dailycare-db-password and friends for the secrets, which did not match secrets_inventory
-- in this same directory - two names for the same four secrets, inside one package, and
-- nothing checking. Inktree's names are the ones the register already used. See
-- secret_names_agree in the checks.

INSERT INTO gcp_iam (environment, principal, kind, role, scope_kind, scope_refs, why) VALUES
('dev','dc-dev-api','service_account','roles/cloudsql.client','project',NULL,NULL),
('dev','dc-dev-api','service_account','roles/cloudsql.instanceUser','project',NULL,
 'Inert until the instance carries cloudsql.iam_authentication=on and a CLOUD_IAM_SERVICE_ACCOUNT user exists. It leaves the option of dropping the password open.'),
('dev','dc-dev-api','service_account','roles/secretmanager.secretAccessor','secret',
 ARRAY['db_password','jwt_signing_key','twilio_token'],
 'Three named secrets, not the project, and not pointclickcare_client. That credential is the only thing stopping a stolen session writing a medication event attributed to the clinical system.'),
('dev','dc-dev-api','service_account','roles/iam.serviceAccountTokenCreator','service_account',
 ARRAY['dc-dev-api'],
 'Signs photo URLs through signBlob without ever holding a key. On itself: at project level this role is impersonation of everything. This is the mechanism behind the platform_managed row for media_signing_key in secrets_inventory.'),
('dev','dc-dev-api','service_account','roles/logging.logWriter','project',NULL,NULL),
-- These two were not designed, they were found. The handover said the api account holds
-- "logging, trace, metrics" and the exact role strings were deliberately not guessed at;
-- the first drift run against the real console reported them as granted and not declared,
-- which is the mechanism doing its job in the direction that matters. Both are write-only
-- telemetry and neither reads anything, so they are declared rather than questioned.
('dev','dc-dev-api','service_account','roles/cloudtrace.agent','project',NULL,
 'Found by drift, not designed. Writes spans, reads nothing.'),
('dev','dc-dev-api','service_account','roles/monitoring.metricWriter','project',NULL,
 'Found by drift, not designed. Writes metrics, reads nothing.'),

('dev','dc-dev-retention','service_account','roles/cloudsql.client','project',NULL,NULL),
('dev','dc-dev-retention','service_account','roles/cloudsql.instanceUser','project',NULL,NULL),
('dev','dc-dev-retention','service_account','roles/logging.logWriter','project',NULL,NULL),

('dev','dc-dev-integration','service_account','roles/cloudsql.client','project',NULL,NULL),
('dev','dc-dev-integration','service_account','roles/cloudsql.instanceUser','project',NULL,NULL),
('dev','dc-dev-integration','service_account','roles/secretmanager.secretAccessor','secret',
 ARRAY['pointclickcare_client'],'One secret.'),
('dev','dc-dev-integration','service_account','roles/logging.logWriter','project',NULL,NULL),

('dev','dc-dev-backup','service_account','roles/cloudsql.client','project',NULL,NULL),
('dev','dc-dev-backup','service_account','roles/cloudsql.instanceUser','project',NULL,NULL),
('dev','dc-dev-backup','service_account','roles/logging.logWriter','project',NULL,NULL),

('dev','dc-dev-github-actions','service_account','roles/run.developer','project',NULL,NULL),
('dev','dc-dev-github-actions','service_account','roles/artifactregistry.writer','project',NULL,NULL),
('dev','dc-dev-github-actions','service_account','roles/iam.serviceAccountUser','service_account',
 ARRAY['dc-dev-api','dc-dev-retention','dc-dev-integration','dc-dev-backup'],
 'Deploys as them. No secret and no database reach - CI needs neither, and has been the way into plenty of systems that gave it both. Inktree had this on api and retention only and widened it to match: the integration and backup jobs have to deploy somehow.');

-- ── how CI signs in without a key ─────────────────────────────────────────────
--
-- Found by drift rather than written down: the binding that makes keyless CI work. A
-- GitHub Actions run presents an OIDC token, and this lets a token whose
-- repository_owner claim is dailycare-hq act as the deploy account. No JSON key exists
-- anywhere, which is the point of iam.disableServiceAccountKeyCreation.
--
-- The principal is a set rather than an identity, and the attribute it is pinned on is
-- the whole of the trust. Pinned to the owner, any repository in that org can deploy -
-- which is what Inktree intended and says so, since splitting the backend out of
-- dailycare-mobile should not need an IAM change. Pinned wider than that, or to nothing,
-- and any GitHub repository in the world could.

INSERT INTO gcp_iam (environment, principal, kind, role, scope_kind, scope_refs, why) VALUES
('dev','//iam.googleapis.com/projects/144065101336/locations/global/workloadIdentityPools/dc-dev-github-pool/attribute.repository_owner/dailycare-hq',
 'federated','roles/iam.workloadIdentityUser','service_account',ARRAY['dc-dev-github-actions'],
 'Keyless CI. The trust is the attribute in the principal: repository_owner = dailycare-hq, so any repository in that org deploys and nothing outside it can.');

-- Staging mirrors dev with dc-stg names. Same shape, so the differences between the two
-- environments are the ones above rather than ones nobody meant.
INSERT INTO gcp_iam (environment, principal, kind, role, scope_kind, scope_refs, why)
SELECT 'staging', replace(principal,'dc-dev-','dc-stg-'), kind, role, scope_kind,
       CASE WHEN scope_kind = 'service_account'
            THEN (SELECT array_agg(replace(r,'dc-dev-','dc-stg-')) FROM unnest(scope_refs) r)
            ELSE scope_refs END,
       why
FROM gcp_iam WHERE environment = 'dev' AND kind = 'service_account'
  -- Not the federated principal: staging has a pool of its own, with its own project
  -- number in the name, so copying dev's would name a pool that does not exist there.
  -- The federated principal is excluded by its kind: staging has a pool of its own, with
  -- its own project number in the name, so copying dev's would name one that is not there.
  AND kind = 'service_account';


-- ── the buckets ───────────────────────────────────────────────────────────────
--
-- Named after the project, which is the convention Inktree's own state bucket already
-- uses. This file first said dc-dev-media, matching the service accounts, while the
-- Terraform that made them said inktree-dailycare-dev-media - two files of mine
-- disagreeing, found by loading the real bucket policies and seeing the same four
-- bindings reported in both directions at once.
--
-- Creating them is ours, in dev. These rows are declared and not granted, and
-- gcp_iam_drift will say so until the buckets are made - which is the correct report, not
-- a failure: the control cannot exist before the thing it controls.
--
-- objectCreator rather than objectAdmin on the api account. objectAdmin includes
-- objects.delete, and GCS also requires objects.delete to overwrite an existing object - so
-- objectCreator forbids both, which is what a photograph attached to a care record wants.
-- The first version of this file gave the api objectAdmin and the checks caught it.

INSERT INTO gcp_iam (environment, principal, kind, role, scope_kind, scope_refs, why) VALUES
('dev','dc-dev-api','service_account','roles/storage.objectCreator','bucket',ARRAY['inktree-dailycare-dev-media'],
 'Create and never replace. An overwrite to the same path would replace evidence with no trace.'),
('dev','dc-dev-api','service_account','roles/storage.objectViewer','bucket',ARRAY['inktree-dailycare-dev-media'],NULL),
('dev','dc-dev-retention','service_account','roles/storage.objectAdmin','bucket',ARRAY['inktree-dailycare-dev-media'],
 'objectAdmin here on purpose: it is the delete half of the retention handshake, and this is the only principal that gets it.'),
('dev','dc-dev-backup','service_account','roles/storage.objectAdmin','bucket',ARRAY['inktree-dailycare-dev-backup'],NULL);


-- ── the guardrails ─────────────────────────────────────────────────────────────
--
-- Org policies, applying to Inktree as much as to us. Recorded because they are controls
-- and a control that only exists in somebody's handover document is a sentence.

CREATE TABLE gcp_guardrails (
  constraint_name text PRIMARY KEY,
  what            text NOT NULL,
  why             text,
  applies_to      text NOT NULL,

  -- When somebody last asked the project rather than the document. "We checked once" and
  -- "it is still true" are different statements and only one of them ages.
  confirmed_on    date
);

-- Every row below was confirmed on 22 September against inktree-dailycare-dev with
--   gcloud resource-manager org-policies describe <constraint> --project=<id>
-- The three boolean ones came back enforced and resourceLocations came back in:us-locations.
INSERT INTO gcp_guardrails (constraint_name, what, why, applies_to, confirmed_on) VALUES
('iam.disableServiceAccountKeyCreation',
 'No service-account JSON keys can be created, for us or for CI.',
 'encryption-and-secrets.sql calls a downloaded key the classic breach vector. This makes it structural rather than a rule: deploys impersonate, and CI authenticates through Workload Identity Federation with nothing stored.',
 'all three projects', DATE '2026-09-22'),
('sql.restrictPublicIp',
 'Cloud SQL cannot be given a public address.',
 'The design said the instance has no public address. This makes that unskippable rather than a setting somebody could change in a hurry.',
 'all three projects', DATE '2026-09-22'),
('storage.publicAccessPrevention',
 'Buckets cannot be made public.',
 'Signed URLs still work; this only forecloses allUsers.',
 'all three projects', DATE '2026-09-22'),
('gcp.resourceLocations',
 'Resources must be created in US locations. The value is in:us-locations.',
 'A BAA covers the processing, not the geography, and the facilities are US ones. Picking us-central1 everywhere means this is never noticed, which is the point of a guardrail.',
 'all three projects', DATE '2026-09-22'),
('dataAccessAuditLogs',
 'Data Access audit logging is on for all services: ADMIN_READ, DATA_READ, DATA_WRITE.',
 'Off by default in a new project. This is the who-looked-at-which-resource trail, and it is the infrastructure half of the read-auditing gap audit-logging.sql flags on the database side.',
 'dev and staging', DATE '2026-09-22');


-- ── what is still Inktree's ────────────────────────────────────────────────────

CREATE VIEW iam_theirs AS
SELECT * FROM (VALUES
  ('the projects, the billing account and the org policies'),
  ('the BAA, and re-checking the Included Products list when we add a service'),
  ('granting IAM at project level - we hold no projectIamAdmin anywhere'),
  ('the project-level Terraform: policies, audit config, identities, secret shells, WIF, registry, budgets'),
  ('secret values in staging'),
  ('production, which stays empty until the M6 gate')
) AS t(item);

COMMENT ON VIEW iam_theirs IS
  'Application infrastructure - Cloud SQL, Cloud Run, the buckets, the VPC connector - is
   ours, in its own Terraform state, reading their identities as data sources rather than
   recreating them.';


-- ── the commands ───────────────────────────────────────────────────────────────

CREATE FUNCTION iam_member(p text, k iam_principal_kind, proj text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, public AS $$
  SELECT CASE WHEN k = 'person' THEN 'user:' || p
              ELSE 'serviceAccount:' || p || '@' || proj || '.iam.gserviceaccount.com' END
$$;

CREATE VIEW iam_grant_commands AS
SELECT g.environment, p.project_id, g.principal, g.expires_on,
  CASE g.scope_kind
    WHEN 'project' THEN format(
      'gcloud projects add-iam-policy-binding %s --member=%s --role=%s',
      p.project_id, iam_member(g.principal, g.kind, p.project_id), g.role)
    WHEN 'secret' THEN format(
      'gcloud secrets add-iam-policy-binding %s --project=%s --member=%s --role=%s',
      r, p.project_id, iam_member(g.principal, g.kind, p.project_id), g.role)
    WHEN 'bucket' THEN format(
      'gcloud storage buckets add-iam-policy-binding gs://%s --member=%s --role=%s',
      r, iam_member(g.principal, g.kind, p.project_id), g.role)
    WHEN 'service_account' THEN format(
      'gcloud iam service-accounts add-iam-policy-binding %s@%s.iam.gserviceaccount.com --member=%s --role=%s',
      r, p.project_id, iam_member(g.principal, g.kind, p.project_id), g.role)
    WHEN 'repository' THEN format(
      'gcloud artifacts repositories add-iam-policy-binding %s --location=%s --member=%s --role=%s',
      r, p.region, iam_member(g.principal, g.kind, p.project_id), g.role)
  END AS command
FROM gcp_iam g
JOIN gcp_projects p ON p.environment = g.environment
LEFT JOIN LATERAL unnest(coalesce(g.scope_refs, ARRAY[NULL::text])) AS r ON true
ORDER BY g.environment, g.kind, g.principal, g.role, r;

COMMENT ON VIEW iam_grant_commands IS
  'Real commands with the real project ids. Most of these are already applied - this is what
   would reproduce the policy, and what to run for the bucket bindings once the buckets are
   made.';

CREATE VIEW iam_expiring AS
SELECT environment, principal, role, scope_kind, expires_on,
       expires_on - current_date AS days_left
FROM gcp_iam WHERE expires_on IS NOT NULL
ORDER BY expires_on, principal;

COMMENT ON VIEW iam_expiring IS
  'Staging closes on its own. Ask this before assuming an afternoon of permission errors is
   a bug.';


-- ── drift, which is the part that makes any of this a control ──────────────────
--
-- Everything above is a claim. app_privileges has the same problem and solves it by
-- comparing against information_schema; this is the same shape against a real policy.
--
-- Load it with the output of, per project:
--
--   gcloud projects get-iam-policy inktree-dailycare-dev --format=json
--
-- then insert one row per binding member. Nothing here reaches out to Google on its own -
-- a database that can call a cloud API is a different and worse thing than one that cannot.

CREATE TABLE gcp_iam_observed (
  environment  gcp_environment NOT NULL REFERENCES gcp_projects(environment),
  principal    text NOT NULL,
  role         text NOT NULL,
  scope_kind   iam_scope_kind NOT NULL DEFAULT 'project',

  -- Empty string rather than null for a project-scoped binding, so the primary key is a
  -- plain one. A key over COALESCE(scope_ref,'') is not something a table constraint can
  -- express, and the alternative - nullable, with a partial unique index each way - is two
  -- indexes and a footnote for no gain.
  scope_ref    text NOT NULL DEFAULT '',

  has_condition boolean NOT NULL DEFAULT false,

  -- Google creates these when an API is enabled and maintains them itself. Nobody granted
  -- them and nobody can meaningfully remove them, so they are recorded and marked rather
  -- than filtered out: a reviewer should see the whole policy, and reporting thirty of
  -- them as undeclared over-grants would bury the two lines that matter.
  google_managed boolean NOT NULL DEFAULT false,

  observed_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (environment, principal, role, scope_kind, scope_ref)
);

COMMENT ON TABLE gcp_iam_observed IS
  'What a real policy actually says, loaded from a gcloud dump or read off the console.
   Empty until somebody loads one, and gcp_iam_drift says so rather than reporting
   agreement.';

-- What a load actually looked at. get-iam-policy on a project returns project-level
-- bindings and nothing else - a secret, a bucket and a service account each carry their own
-- policy and have to be asked separately. Without this, the first real load reports every
-- secret binding as missing, and a drift report that cries wolf on its first outing is a
-- drift report nobody opens again.
CREATE TABLE gcp_iam_observations (
  environment gcp_environment NOT NULL REFERENCES gcp_projects(environment),
  scope_kind  iam_scope_kind NOT NULL,
  scope_ref   text NOT NULL DEFAULT '',
  source      text NOT NULL,
  observed_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (environment, scope_kind, scope_ref)
);

COMMENT ON TABLE gcp_iam_observations IS
  'One row per policy actually read. Drift only compares scopes that appear here.';

CREATE VIEW gcp_iam_drift AS
WITH declared AS (
  SELECT g.environment, g.principal, g.role, g.scope_kind,
         unnest(coalesce(g.scope_refs, ARRAY[NULL::text])) AS scope_ref
  FROM gcp_iam g
  -- Only where a policy of that shape was actually read. A binding on a bucket nobody
  -- looked at is unknown, and unknown is not the same as missing.
  WHERE EXISTS (SELECT 1 FROM gcp_iam_observations o
                WHERE o.environment = g.environment AND o.scope_kind = g.scope_kind)
)
SELECT 'declared, not granted' AS direction, d.environment, d.principal, d.role,
       d.scope_kind, d.scope_ref
FROM declared d
LEFT JOIN gcp_iam_observed o
  ON o.environment = d.environment AND o.principal = d.principal AND o.role = d.role
 AND o.scope_kind = d.scope_kind AND o.scope_ref = coalesce(d.scope_ref,'')
WHERE o.principal IS NULL
UNION ALL
SELECT 'granted, not declared', o.environment, o.principal, o.role, o.scope_kind, o.scope_ref
FROM gcp_iam_observed o
LEFT JOIN declared d
  ON d.environment = o.environment AND d.principal = o.principal AND d.role = o.role
 AND d.scope_kind = o.scope_kind AND coalesce(d.scope_ref,'') = o.scope_ref
WHERE d.principal IS NULL AND NOT o.google_managed;

COMMENT ON VIEW gcp_iam_drift IS
  'Both directions. "Granted, not declared" is the half that finds an over-grant nobody wrote
   down; "declared, not granted" finds a control that was designed and never applied. The
   bucket rows sit in the second until the buckets exist.';

-- The question the first version of this file could not answer. Asked of the real policy,
-- not of the table above.
CREATE VIEW iam_broad_in_practice AS
SELECT environment, principal, role, google_managed
FROM gcp_iam_observed
WHERE (role IN ('roles/owner','roles/editor','roles/viewer')
   OR role LIKE '%.admin'
   OR role LIKE '%projectIamAdmin%'
   OR role LIKE '%securityAdmin%'
   -- Project-level token creation is impersonation of everything in the project. The
   -- handover makes this argument itself about the api account, where it is scoped to
   -- the account rather than the project.
   OR (role = 'roles/iam.serviceAccountTokenCreator' AND scope_kind = 'project'))
  AND NOT google_managed;

COMMENT ON VIEW iam_broad_in_practice IS
  'Dev will appear here and that is expected and argued for in this file. Staging or
   production appearing here is not.';


CREATE VIEW gcp_iam_unobserved AS
SELECT g.environment, g.scope_kind, count(*) AS declared_bindings
FROM gcp_iam g
WHERE NOT EXISTS (SELECT 1 FROM gcp_iam_observations o
                  WHERE o.environment = g.environment AND o.scope_kind = g.scope_kind)
GROUP BY 1, 2 ORDER BY 1, 2;

COMMENT ON VIEW gcp_iam_unobserved IS
  'Declared and never checked against anything. The honest half of a drift report: silence
   here is the only silence that means agreement.';


-- ── the things that are wider than we would have chosen ────────────────────────
--
-- Found by reading the real policy rather than by reading the handover, which described
-- dev's grants by service rather than by role. None of them is a mistake; all three are
-- ordinary parts of a self-serve sandbox and all three are wider than the sentence that
-- justified the sandbox. Recorded the way administrative_controls records a gap: with an
-- owner and what it needs, so it is a question waiting for an answer rather than a silence.
--
-- The checks assert these are recorded and owned. They do not assert they are resolved,
-- because a suite that fails until somebody else answers a question is a suite people
-- learn to run with one known failure - and then with two.

CREATE TABLE iam_open_questions (
  id           text PRIMARY KEY,
  environment  gcp_environment NOT NULL REFERENCES gcp_projects(environment),
  principal    text NOT NULL,
  role         text NOT NULL,
  question     text NOT NULL,
  owner        text NOT NULL,
  raised_on    date NOT NULL,
  answered_on  date,
  answer       text,
  CHECK ((answered_on IS NULL) = (answer IS NULL))
);

INSERT INTO iam_open_questions (id, environment, principal, role, question, owner, raised_on) VALUES
('viewer_is_a_basic_role','dev','jenith.dev1202@gmail.com','roles/viewer',
 'The handover names owner and editor as deliberately absent. viewer is the third basic role and reads everything in the project, including whatever is added to it later. The named roles already carry the reads that get used, so this may be removable - worth asking rather than assuming it was deliberate.',
 'Inktree', DATE '2026-09-22'),

('project_wide_impersonation','dev','jenith.dev1202@gmail.com','roles/iam.serviceAccountTokenCreator',
 'At project level this is impersonation of every service account in the project. The handover makes exactly this argument about the api account, where it is scoped to the account rather than the project. Removing it outright is probably wrong - the no-keys policy means deploys run by impersonation - so the likely answer is scoping it to the four rather than the project.',
 'Inktree', DATE '2026-09-22'),

('service_account_admin','dev','jenith.dev1202@gmail.com','roles/iam.serviceAccountAdmin',
 'Creates and deletes service accounts. Using the four that exist does not need it. May have come along with the impersonation grant.',
 'Inktree', DATE '2026-09-22'),

('staging_cannot_be_checked','staging','jenith.dev1202@gmail.com','roles/resourcemanager.projects.getIamPolicy',
 'Reading a project policy needs getIamPolicy, which the deploy-only set does not carry - so gcp_iam_drift can say nothing about staging. Either a read role goes on, or Inktree runs load-iam-policy.sh there. Not urgent while staging is empty; it stops being fine the moment something is deployed to it.',
 'Inktree', DATE '2026-09-22');

CREATE VIEW iam_questions_outstanding AS
SELECT id, environment, principal, role, owner, raised_on,
       current_date - raised_on AS days_open
FROM iam_open_questions WHERE answered_on IS NULL
ORDER BY raised_on, id;
