-- Backup and recovery
--
-- Applied after vendors.sql.
--
-- A reviewer asks five things about backups. Four have documentary answers: they are taken
-- on this schedule, kept this long, encrypted this way, restorable by these people. The
-- fifth is the one that separates a real answer from a paper one — has anybody ever
-- restored one — and it is the only one that cannot be answered by writing it down.
--
-- So the drill is a script (restore-drill.sh) and its results are rows. A policy with no
-- drill behind it is visible as a gap rather than as a paragraph somebody trusts.
--
-- There is a sixth question nobody asks and it is where the breach comes from: what
-- happens to the copy afterwards. A restored production snapshot is production data
-- sitting in a database with a development name. The control for that is in
-- environments.sql, where the database works out for itself that it is a copy and serves
-- nothing until it has been scrubbed. What is here is the record that somebody proved it.


CREATE TABLE backup_policies (
  environment       deployment_environment PRIMARY KEY,

  -- False while the infrastructure does not exist. A policy nobody has implemented is a
  -- plan, and calling it a control is how a package becomes fiction.
  in_effect         boolean NOT NULL DEFAULT false,

  schedule          text NOT NULL,
  retention_days    integer NOT NULL,
  pitr_window_hours integer NOT NULL,

  -- Targets, not measurements. What a drill records is the measurement.
  rpo_minutes       integer NOT NULL,
  rto_minutes       integer NOT NULL,

  encryption        text NOT NULL,
  key_management    text NOT NULL,
  storage_location  text NOT NULL,
  who_may_restore   text NOT NULL,

  note              text,
  reviewed_on       date NOT NULL,
  CHECK (retention_days > 0 AND pitr_window_hours >= 0),
  CHECK (rpo_minutes >= 0 AND rto_minutes > 0)
);

COMMENT ON COLUMN backup_policies.rpo_minutes IS
  'How much work the facility can afford to lose. For a care record this is small: a
   caregiver who filed a day and had it disappear has to remember it again, and by the end
   of a shift they cannot.';

COMMENT ON COLUMN backup_policies.rto_minutes IS
  'How long the building can run without the app. Longer than it looks - a facility that
   loses DailyCare falls back to paper for the shift, which is what it did before. The
   figure that matters is being back before the next handover.';


INSERT INTO backup_policies (environment, in_effect, schedule, retention_days,
  pitr_window_hours, rpo_minutes, rto_minutes, encryption, key_management,
  storage_location, who_may_restore, note, reviewed_on) VALUES

('production', false,
 'Managed daily snapshot, plus continuous write-ahead log archiving for point-in-time recovery.',
 35, 168, 5, 120,
 'At rest by the platform, in transit by TLS. The snapshot inherits the instance''s encryption; a backup is not a weaker copy of the database.',
 'Platform-managed keys to begin with. Customer-managed keys are a later decision and change who can make a backup unreadable, which is a question about key loss as much as key theft.',
 'Same region as the instance, plus one cross-region copy. A backup in the region that just failed is not a backup.',
 'The recovery role only. Not the deployment account, and not a person''s own credentials.',
 'Thirty-five days of snapshots against seven of point-in-time: the long window is for a corruption nobody noticed for a month, the short one for the mistake somebody noticed in an hour.',
 DATE '2026-09-15'),

('staging', false,
 'Weekly snapshot. Nothing continuous, because nothing here is irreplaceable.',
 14, 0, 1440, 480,
 'At rest by the platform, in transit by TLS.',
 'Platform-managed keys.',
 'Same region. No cross-region copy: losing staging costs a rebuild, not a record.',
 'The recovery role.',
 'Holds scrubbed data only, so a lost staging backup is a lost afternoon rather than an incident.',
 DATE '2026-09-15'),

('development', false,
 'None. A development database is rebuilt from a scrubbed snapshot rather than restored.',
 1, 0, 10080, 1440,
 'At rest by the platform.',
 'Platform-managed keys.',
 'Not stored.',
 'Anyone on the team.',
 'Deliberately nothing to back up. A developer who loses their database runs the restore drill, which is the same procedure as the one being tested.',
 DATE '2026-09-15');


-- ════════════════════════════════════════════════════════════════════ the drill

CREATE TABLE restore_drills (
  id                 bigserial PRIMARY KEY,
  performed_on       date NOT NULL,
  performed_by       text NOT NULL,
  environment        deployment_environment NOT NULL REFERENCES backup_policies(environment),

  source_snapshot_at timestamptz NOT NULL,
  restored_into      text NOT NULL,
  minutes_to_restore integer NOT NULL,
  rows_verified      bigint NOT NULL,

  -- The two that make a drill about confidentiality and not only about availability.
  copy_detected      boolean NOT NULL,   -- the restored copy refused to serve
  scrub_confirmed    boolean NOT NULL,   -- and held nothing of the original afterwards

  outcome            text NOT NULL CHECK (outcome IN ('passed', 'failed')),
  note               text,

  -- A drill into anything but production that passed without proving both of those has
  -- proved that the data came back, and nothing about where it went.
  CHECK (outcome = 'failed' OR environment = 'production'
         OR (copy_detected AND scrub_confirmed)),
  CHECK (minutes_to_restore >= 0 AND rows_verified >= 0)
);

INSERT INTO restore_drills (performed_on, performed_by, environment, source_snapshot_at,
  restored_into, minutes_to_restore, rows_verified, copy_detected, scrub_confirmed,
  outcome, note) VALUES
(DATE '2026-09-15', 'Algene Pulido', 'development', TIMESTAMPTZ '2026-09-15 00:00Z',
 'dc_dev', 1, 13, true, true, 'passed',
 'Run against the model rather than an instance, since none exists yet. A populated database was dumped, restored under a different name, and queried as the application with a care manager identified: the same query that returned a resident and a care note in the source returned zero rows in the copy. Relabelling it development was not enough on its own. After the scrub the gate opened and the note was filler.');


-- ════════════════════════════════════════════════════════════════════ the questions

CREATE VIEW backup_gaps AS
SELECT e AS environment
FROM unnest(enum_range(NULL::deployment_environment)) AS e
WHERE NOT EXISTS (SELECT 1 FROM backup_policies p WHERE p.environment = e);

COMMENT ON VIEW backup_gaps IS
  'Must be empty. "None, and here is why" is a policy and belongs in the table. An
   environment with no row is one nobody has thought about.';

CREATE VIEW drill_overdue AS
SELECT p.environment,
       (SELECT max(d.performed_on) FROM restore_drills d
        WHERE d.environment = p.environment AND d.outcome = 'passed') AS last_passed
FROM backup_policies p
WHERE (SELECT max(d.performed_on) FROM restore_drills d
       WHERE d.environment = p.environment AND d.outcome = 'passed')
      IS DISTINCT FROM NULL
  AND (SELECT max(d.performed_on) FROM restore_drills d
       WHERE d.environment = p.environment AND d.outcome = 'passed')
      < current_date - 180;

COMMENT ON VIEW drill_overdue IS
  'Must be empty. A restore procedure that worked six months ago and has not been run since
   is a procedure, not a capability. Environments that have never been drilled are in
   never_drilled instead, so the two questions do not hide each other.';

CREATE VIEW never_drilled AS
SELECT p.environment, p.in_effect
FROM backup_policies p
WHERE NOT EXISTS (SELECT 1 FROM restore_drills d
                  WHERE d.environment = p.environment AND d.outcome = 'passed');

COMMENT ON VIEW never_drilled IS
  'Expected to have rows while the infrastructure does not exist, and expected to be empty
   before the first real record is written. Separate from drill_overdue because "we have
   never done this" and "we have not done this lately" are different answers and a reviewer
   is owed the first one plainly.';

CREATE VIEW in_effect_without_drill AS
SELECT p.environment FROM backup_policies p
WHERE p.in_effect
  AND NOT EXISTS (SELECT 1 FROM restore_drills d
                  WHERE d.environment = p.environment AND d.outcome = 'passed');

COMMENT ON VIEW in_effect_without_drill IS
  'Must be empty, and it is the rule the other two views exist to serve: a backup policy
   may not be in effect until somebody has restored from it. Empty today because nothing is
   in effect yet, which is the honest reason and not a passing grade.';

CREATE VIEW rto_missed AS
SELECT d.id, d.environment, d.performed_on, d.minutes_to_restore, p.rto_minutes
FROM restore_drills d
JOIN backup_policies p ON p.environment = d.environment
WHERE d.outcome = 'passed' AND d.minutes_to_restore > p.rto_minutes;

COMMENT ON VIEW rto_missed IS
  'Must be empty. A drill that took longer than the target did not pass, whatever it says:
   the target is wrong or the procedure is, and either way somebody has to look.';

CREATE VIEW policies_not_in_effect AS
SELECT environment, schedule FROM backup_policies WHERE NOT in_effect;

COMMENT ON VIEW policies_not_in_effect IS
  'Everything here is a plan rather than a control. Shown to the reviewer as such, because
   a package that presents intentions as implementations is worse than one with gaps.';


DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dailycare_app') THEN
    REVOKE ALL ON backup_policies, restore_drills FROM dailycare_app;
  END IF;
END $$;
