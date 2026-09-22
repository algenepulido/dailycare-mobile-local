-- Checks on gcp-iam.sql.
--
-- The first version of this file asserted "nothing broad" against gcp_iam, which is the
-- table gcp-iam.sql writes. So it proved our list contained no admin roles and said nothing
-- at all about what the projects grant. Inktree pointed that out, and they were right: dev
-- holds several roles it would have matched, and the check passed anyway.
--
-- So the shape here is now the one grants.sql already used for the database. Claims about
-- the model are checked against the model; claims about a real policy are checked against a
-- loaded policy, and when none has been loaded that is reported rather than passed over.

\set QUIET on
SET client_min_messages TO notice;
SELECT checks_begin();

CREATE OR REPLACE FUNCTION expect(label text, condition boolean) RETURNS void AS $$
BEGIN
  IF condition THEN RAISE NOTICE 'PASS  %', label;
  ELSE            RAISE NOTICE 'FAIL  %', label;
  END IF;
END; $$ LANGUAGE plpgsql;
\set QUIET off

\echo ''
\echo '── the separations the roles exist for'

-- The one that matters. The feed's credential is what stops a stolen application session
-- writing a medication event that a family reads as a clinical record.
SELECT expect('no api account anywhere can read the clinical feed''s credential',
  NOT EXISTS (SELECT 1 FROM gcp_iam
              WHERE principal LIKE '%-api'
                AND 'pointclickcare_client' = ANY(scope_refs)));

SELECT expect('CI deploys and holds no secret and no database role, in either environment',
  (SELECT count(*) = 0 FROM gcp_iam
   WHERE principal LIKE '%-github-actions'
     AND (role LIKE '%secretmanager%' OR role LIKE '%cloudsql%')));

SELECT expect('and CI can act as all four identities, since two of the jobs deploy too',
  (SELECT count(*) = 2 FROM gcp_iam
   WHERE principal LIKE '%-github-actions'
     AND role = 'roles/iam.serviceAccountUser'
     AND array_length(scope_refs, 1) = 4));

SELECT expect('a service account''s token creation is on itself, never the project',
  (SELECT bool_and(scope_kind = 'service_account' AND array_length(scope_refs,1) = 1
                   AND scope_refs[1] = principal)
   FROM gcp_iam
   WHERE role = 'roles/iam.serviceAccountTokenCreator' AND kind = 'service_account'));

-- A person holds it project-wide in dev, which the handover's own argument about the api
-- account points at. That is a question for Inktree rather than a thing to assert away, so
-- what is checked is that it is written down with an owner.
SELECT expect('and where a person holds it project-wide, that is recorded as a question',
  NOT EXISTS (
    SELECT 1 FROM gcp_iam g
    WHERE g.role = 'roles/iam.serviceAccountTokenCreator'
      AND g.kind = 'person' AND g.scope_kind = 'project'
      AND NOT EXISTS (SELECT 1 FROM iam_open_questions q
                      WHERE q.principal = g.principal AND q.role = g.role
                        AND q.environment = g.environment)));

\echo ''
\echo '── the media bucket'

-- objectAdmin includes objects.delete, and GCS needs objects.delete to overwrite as well.
-- The api account had it in the first draft, which would have let it replace a photograph
-- with the retention handshake never happening.
SELECT expect('only retention may delete from a media bucket',
  (SELECT array_agg(DISTINCT principal) = ARRAY['dc-dev-retention'] FROM gcp_iam
   WHERE scope_kind = 'bucket' AND scope_refs && ARRAY['dc-dev-media']
     AND role = 'roles/storage.objectAdmin'));

SELECT expect('and the api account can put one there and read it back, and nothing else',
  (SELECT array_agg(role ORDER BY role) = ARRAY['roles/storage.objectCreator','roles/storage.objectViewer']
   FROM gcp_iam WHERE principal = 'dc-dev-api' AND scope_kind = 'bucket'));

\echo ''
\echo '── the two environments differ only where somebody meant them to'

SELECT expect('production grants nobody anything',
  (SELECT count(*) = 0 FROM gcp_iam WHERE environment = 'prod'));

-- We hold none of these. Inktree owning their own projects is correct and is recorded
-- rather than excluded, so the check names whose access it is about instead of pretending
-- the binding is not there.
SELECT expect('we hold no owner or editor anywhere, and cannot grant IAM',
  (SELECT count(*) = 0 FROM gcp_iam
   WHERE principal = 'jenith.dev1202@gmail.com'
     AND (role IN ('roles/owner','roles/editor')
          OR role LIKE '%projectIamAdmin%' OR role LIKE '%securityAdmin%')));

SELECT expect('and the only owner recorded is Inktree',
  (SELECT array_agg(DISTINCT principal) = ARRAY['production@inktree.ai']
   FROM gcp_iam WHERE role = 'roles/owner'));

-- Dev holds admin roles deliberately. The argument only holds while dev has no real data
-- in it, so the check is the asymmetry rather than a flat ban that would be wrong here.
SELECT expect('the admin roles a person holds are in dev and nowhere else',
  (SELECT count(*) = 0 FROM gcp_iam
   WHERE kind = 'person' AND role LIKE '%.admin' AND environment <> 'dev'));

SELECT expect('and no service account holds an admin role in any environment',
  (SELECT count(*) = 0 FROM gcp_iam WHERE kind = 'service_account' AND role LIKE '%.admin'));

SELECT expect('every staging binding expires, and no dev binding does',
  (SELECT bool_and((environment = 'staging') = (expires_on IS NOT NULL))
   FROM gcp_iam WHERE kind = 'person'));

SELECT expect('the service accounts have the same roles in staging as in dev',
  (SELECT count(*) = 0 FROM (
     SELECT role, scope_kind FROM gcp_iam
      WHERE environment = 'dev' AND kind = 'service_account' AND scope_kind <> 'bucket'
     EXCEPT
     SELECT role, scope_kind FROM gcp_iam
      WHERE environment = 'staging' AND kind = 'service_account') x));

\echo ''
\echo '── the names, which is where this package contradicted itself'

-- gcp-iam.sql invented dailycare-db-password and friends while secrets_inventory in this
-- same directory already called them db_password and friends. Two names for four secrets,
-- in one package, and nothing looking. Inktree provisioned the register's names.
SELECT expect('every secret a role can read is one the inventory knows about',
  (SELECT count(*) = 0 FROM (
     SELECT DISTINCT unnest(scope_refs) AS s FROM gcp_iam WHERE scope_kind = 'secret'
     EXCEPT SELECT id FROM secrets_inventory) x));

SELECT expect('and every secret the inventory says lives in a manager can be read by something',
  (SELECT count(*) = 0 FROM secrets_inventory si
   WHERE si.store = 'secret_manager'
     AND NOT EXISTS (SELECT 1 FROM gcp_iam g
                     WHERE g.scope_kind = 'secret' AND si.id = ANY(g.scope_refs))));

SELECT expect('service account names match their project''s environment',
  (SELECT bool_and(principal LIKE CASE environment WHEN 'dev' THEN 'dc-dev-%' ELSE 'dc-stg-%' END)
   FROM gcp_iam WHERE kind = 'service_account'));

\echo ''
\echo '── and the commands are commands'

SELECT expect('every binding produces a real command',
  (SELECT count(*) = 0 FROM iam_grant_commands WHERE command IS NULL));

SELECT expect('with a real project id in it',
  (SELECT bool_and(command LIKE '%inktree-dailycare-%') FROM iam_grant_commands));

\echo ''
\echo '── against a real policy, which is the only part that is evidence'

-- Reported rather than passed. An empty observation table is the normal state between
-- dumps, and saying "no drift" about it would be the same mistake this file started with.
SELECT CASE WHEN (SELECT count(*) FROM gcp_iam_observed) = 0
  THEN 'NOTE  no policy has been loaded into gcp_iam_observed, so nothing below is evidence yet.'
  ELSE 'NOTE  ' || (SELECT count(*)::text FROM gcp_iam_observed) || ' observed bindings loaded.'
END;

SELECT expect('nothing broad in staging or production, asked of the real policy',
  (SELECT count(*) = 0 FROM iam_broad_in_practice WHERE environment <> 'dev'));

-- Not a failure, a list. Dev is meant to be wide and the argument for it is in gcp-iam.sql;
-- what is not wanted is for it to widen further without anybody saying so, and a drift of
-- zero against a policy that was actually read is what says it has not.
SELECT 'NOTE  ' || count(*)::text || ' broad roles in dev, all declared and argued for'
FROM iam_broad_in_practice WHERE environment = 'dev';

-- Basic roles are the thing the whole exercise was to avoid. The handover names owner and
-- editor as deliberately absent; viewer is the third of the three and reads everything in
-- the project including whatever is added later.
SELECT expect('no basic role is held by anything that is not a person',
  (SELECT count(*) = 0 FROM gcp_iam_observed
   WHERE role IN ('roles/owner','roles/editor','roles/viewer')
     AND NOT google_managed
     AND principal NOT LIKE '%@%'));

SELECT expect('nothing is granted that was never declared',
  (SELECT count(*) = 0 FROM gcp_iam_drift WHERE direction = 'granted, not declared'));

\echo ''
\echo '── the guardrails are recorded, because a control in a document is a sentence'

SELECT expect('the four org policies and the audit config are written down',
  (SELECT count(*) >= 5 FROM gcp_guardrails));

-- Confirmed against the real project on 22 September with
--   gcloud resource-manager org-policies describe <constraint> --project=inktree-dailycare-dev
-- All four enforced. Recorded as a date rather than a claim, because "we checked once" and
-- "it is still true" are different statements and only one of them ages.
SELECT expect('and each one says when it was last confirmed against a project',
  (SELECT bool_and(confirmed_on IS NOT NULL) FROM gcp_guardrails));

SELECT expect('including the one that removes the key nobody should be downloading',
  EXISTS (SELECT 1 FROM gcp_guardrails
          WHERE constraint_name = 'iam.disableServiceAccountKeyCreation'));

SELECT expect('every open question has an owner and a date',
  (SELECT bool_and(owner <> '' AND raised_on IS NOT NULL) FROM iam_open_questions));

SELECT 'NOTE  ' || count(*)::text || ' IAM questions outstanding with Inktree'
FROM iam_questions_outstanding;

SELECT expect('and every guardrail says what it is for',
  (SELECT bool_and(why IS NOT NULL AND length(why) > 20) FROM gcp_guardrails));

SELECT checks_end();
