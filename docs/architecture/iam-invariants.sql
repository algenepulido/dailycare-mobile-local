-- Checks on gcp-iam.sql.
--
-- Short, because most of this is a list and a list is checked by reading it. What is worth
-- a check is the handful of things that would undo the point of writing it down.

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
\echo '── the roles nobody asked for'

SELECT expect('nothing broad',
  (SELECT count(*) = 0 FROM gcp_iam
   WHERE role IN ('roles/owner','roles/editor','roles/viewer')
      OR role LIKE '%.admin'));

SELECT expect('and nobody can grant themselves more',
  (SELECT count(*) = 0 FROM gcp_iam WHERE role LIKE '%projectIamAdmin%'
                                       OR role LIKE '%securityAdmin%'));

\echo ''
\echo '── the separation the roles exist for'

-- The one that matters. The feed's credential is what stops a stolen application session
-- writing a medication event that a family reads as a MedTech record.
SELECT expect('the API cannot read the clinical feed''s credential',
  NOT EXISTS (SELECT 1 FROM gcp_iam
              WHERE principal = 'dailycare-api'
                AND 'dailycare-pointclickcare' = ANY(scope_refs)));

SELECT expect('CI can deploy and cannot read a secret or reach the database',
  (SELECT count(*) = 0 FROM gcp_iam
   WHERE principal = 'github-deploy'
     AND (role LIKE '%secretmanager%' OR role LIKE '%cloudsql%')));

-- objectAdmin includes objects.delete. The API had it, which would have let it remove a
-- photograph with the retention handshake never happening.
--
-- Algene keeps it for M2, and that is on the take-away list rather than hidden here: a
-- person with delete on the media bucket is a person who can remove evidence, which is
-- fine while the bucket holds test images and is not once it holds a resident's.
SELECT expect('nothing that runs unattended can delete from the media bucket except retention',
  (SELECT array_agg(principal ORDER BY principal) = ARRAY['dailycare-retention'] FROM gcp_iam
   WHERE 'dailycare-media' = ANY(scope_refs)
     AND role = 'roles/storage.objectAdmin'
     AND kind = 'service_account'));

SELECT expect('and the person who has it is marked temporary',
  (SELECT bool_and(temporary) FROM gcp_iam
   WHERE 'dailycare-media' = ANY(scope_refs)
     AND role = 'roles/storage.objectAdmin' AND kind = 'person'));

SELECT expect('and the API can put an object there and read one back, and nothing else',
  (SELECT array_agg(role ORDER BY role) = ARRAY['roles/storage.objectCreator','roles/storage.objectViewer']
   FROM gcp_iam WHERE principal = 'dailycare-api' AND 'dailycare-media' = ANY(scope_refs)));

SELECT expect('and token creation is on itself, not the project',
  (SELECT scope_kind = 'service_account' AND scope_refs = ARRAY['dailycare-api']
   FROM gcp_iam WHERE role = 'roles/iam.serviceAccountTokenCreator'));

\echo ''
\echo '── the list is usable'

SELECT expect('every binding produces a command rather than a note to write one',
  (SELECT count(*) = 0 FROM iam_grant_commands WHERE command IS NULL OR command LIKE '#%'));

SELECT expect('what is temporary says so',
  (SELECT count(*) > 0 FROM iam_temporary)
  AND (SELECT count(*) = 0 FROM gcp_iam WHERE temporary AND kind = 'service_account'));

\echo ''
\echo '   what to take away when M2 closes:'
SELECT principal, role FROM iam_temporary ORDER BY role;

\set QUIET on
SELECT checks_end();
DROP FUNCTION expect(text, boolean);
\set QUIET off
