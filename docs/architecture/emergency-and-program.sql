-- Emergency access, and the safeguards that are sentences
--
-- Applied after identity-policies.sql.
--
-- Two things the rule requires that this directory had been quiet about for opposite
-- reasons. One it had decided against on purpose and called a virtue. The other it could
-- not express, because the safeguards are procedures and a procedure is not a constraint -
-- which is true, and is not a reason for them to be absent rather than owned.


-- ════════════════════════════════════════════════════════════════════ breaking glass
--
-- The package says there is no admin bypass in the application path and means it as a
-- guarantee. It is a good one. §164.312(a)(2)(ii) still requires a documented procedure
-- for obtaining protected health information in an emergency, and the case it means is a
-- memory-care facility at three in the morning with a resident in hospital and the manager
-- unreachable.
--
-- So it is a grant with a name, a reason and an end, shaped the way the restore gate is:
-- one deliberate act that records who decided it. Not a role somebody holds.

CREATE TABLE emergency_access (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  facility_id   uuid NOT NULL REFERENCES facilities(id) ON DELETE RESTRICT,
  granted_to    uuid NOT NULL REFERENCES users(id),
  granted_by    text NOT NULL,      -- who authorised it, by name
  reason        text NOT NULL,
  granted_at    timestamptz NOT NULL DEFAULT now(),
  expires_at    timestamptz NOT NULL,
  revoked_at    timestamptz,

  CHECK (expires_at > granted_at),
  -- Eight hours is a shift. A break-glass grant that outlives the emergency is a role.
  CONSTRAINT emergency_access_is_short
    CHECK (expires_at <= granted_at + interval '8 hours'),
  CHECK (length(btrim(reason)) > 20)
);

CREATE INDEX ON emergency_access (granted_to, facility_id) WHERE revoked_at IS NULL;

COMMENT ON TABLE emergency_access IS
  'Every column is a question somebody will ask afterwards. The reason has a length floor
   because "emergency" is not one, and the expiry has a ceiling because the failure mode of
   break-glass is that somebody keeps the glass broken.';

CREATE OR REPLACE FUNCTION app_has_emergency_access(target_facility uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = pg_catalog, public AS $$
  SELECT EXISTS (
    SELECT 1 FROM emergency_access ea
    WHERE ea.granted_to  = app_user_id()
      AND ea.facility_id = target_facility
      AND ea.revoked_at IS NULL
      AND ea.expires_at  > now()
  )
$$;

-- Folded into the manager predicate rather than added beside it, so every policy that
-- already asks "is this a care manager here" gets the answer without being rewritten - and
-- so there is one place to look rather than a second path to remember.
CREATE OR REPLACE FUNCTION app_is_care_manager(target_facility uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = pg_catalog, public AS $$
  SELECT EXISTS (
    SELECT 1 FROM facility_members fm
    WHERE fm.user_id     = app_user_id()
      AND fm.facility_id = target_facility
      AND fm.role        = 'care_manager'
      AND fm.state       = 'active'
      AND fm.ended_at IS NULL
  )
  OR app_has_emergency_access(target_facility)
$$;

COMMENT ON FUNCTION app_is_care_manager(uuid) IS
  'A care manager at this facility, or somebody holding an unexpired emergency grant for
   it. The second is rare, short, named and audited; the first is a job.';

CREATE VIEW emergency_access_open AS
SELECT ea.id, f.name AS facility, u.email AS granted_to, ea.granted_by, ea.reason,
       ea.granted_at, ea.expires_at
FROM emergency_access ea
JOIN facilities f ON f.id = ea.facility_id
JOIN users u ON u.id = ea.granted_to
WHERE ea.revoked_at IS NULL AND ea.expires_at > now();

COMMENT ON VIEW emergency_access_open IS
  'What somebody looks at when they want to know who can currently see more than their job
   gives them. Expected to be empty almost always, and a monitoring signal when it is not.';


-- ════════════════════════════════════════════════════════════════════ the sentences
--
-- Risk analysis, a named security official, workforce procedures, training, a sanction
-- policy, incident response, emergency-mode operation, criticality analysis, an evaluation
-- cadence, a workstation policy, a lost-device procedure. Every one of them is required
-- and none of them is a constraint.
--
-- What this package can do with them is what it does with a vendor agreement it does not
-- hold: give each an owner, a date and a state, so that "not written yet" is a row rather
-- than a silence. The discipline is the same one vendors.sql applies - a gap is allowed, an
-- unowned gap is not.

CREATE TYPE control_status AS ENUM ('absent', 'drafted', 'in_effect');

CREATE TABLE administrative_controls (
  id              text PRIMARY KEY,
  requirement     text NOT NULL,     -- the citation
  what            text NOT NULL,
  owner           text NOT NULL,
  required_before text NOT NULL,
  status          control_status NOT NULL DEFAULT 'absent',
  evidence        text,              -- where it lives once it exists
  reviewed_on     date NOT NULL,

  CONSTRAINT something_in_effect_has_evidence
    CHECK (status <> 'in_effect' OR evidence IS NOT NULL)
);

COMMENT ON CONSTRAINT something_in_effect_has_evidence ON administrative_controls IS
  'A control in effect that nobody can point at is a control in a spreadsheet. The evidence
   column is where the document is, and it is required exactly when the claim is made.';

INSERT INTO administrative_controls (id, requirement, what, owner, required_before, reviewed_on) VALUES
('risk_analysis', '164.308(a)(1)(ii)(A)',
 'An accurate and thorough assessment of the risks to confidentiality, integrity and availability. The preliminary review this package has been through is an input to it, not a substitute.',
 'InkTree, through the named security official', 'the first real record', DATE '2026-09-18'),

('risk_management', '164.308(a)(1)(ii)(B)',
 'What is being done about what the risk analysis found, and by when.',
 'InkTree', 'the first real record', DATE '2026-09-18'),

('security_official', '164.308(a)(2)',
 'A named person responsible for the policies and procedures. One name.',
 'InkTree', 'now', DATE '2026-09-18'),

('workforce_procedures', '164.308(a)(3)',
 'Who authorises a caregiver account, who checks they should have one, who ends it when they leave, and how fast. The mechanisms exist - facility_members.ended_at, users.deactivated_at, revoke_all_sessions() - and nothing invokes them on a schedule anybody agreed.',
 'InkTree with each facility', 'the first real record', DATE '2026-09-18'),

('training', '164.308(a)(5)',
 'Security awareness training, and the record of who had it and when.',
 'InkTree', 'the first real record', DATE '2026-09-18'),

('sanction_policy', '164.308(a)(1)(ii)(C)',
 'What happens to a workforce member who does not follow the policies. Required, and the one nobody enjoys writing.',
 'InkTree', 'the first real record', DATE '2026-09-18'),

('incident_response', '164.308(a)(6)',
 'What the paged engineer does next. incidents.sql gives it somewhere to write the answer down; this is the answer.',
 'InkTree', 'the first real record', DATE '2026-09-18'),

('emergency_mode', '164.308(a)(7)(ii)(C)',
 'How a facility runs a shift when DailyCare is down. It falls back to paper, which is what it did before - and that has to be written, rehearsed and reconciled afterwards rather than improvised at seven in the morning.',
 'InkTree with each facility', 'the first real record', DATE '2026-09-18'),

('criticality_analysis', '164.308(a)(7)(ii)(E)',
 'Which parts of this matter in what order when something is broken.',
 'InkTree', 'the GCP project', DATE '2026-09-18'),

('evaluation_cadence', '164.308(a)(8)',
 'How often verify.sh and the vendor register are run and by whom. The technical evaluation exists and runs in one command; what is missing is somebody whose job it is to run it.',
 'InkTree', 'now', DATE '2026-09-18'),

('workstation_policy', '164.310(b), 164.310(c)',
 'Where a scrubbed copy may live, what a developer laptop must have on it, and what happens when one is lost. environments.sql guards the database side of a restore; nothing guards the laptop it lands on.',
 'InkTree', 'the first restore', DATE '2026-09-18'),

('lost_device', '164.310(d)(1)',
 'What a caregiver does when a phone goes missing, and what happens on the server when they say so. revoke_all_sessions() is half of it.',
 'InkTree with each facility', 'the client ships against real data', DATE '2026-09-18'),

('media_disposal', '164.310(d)(2)',
 'Disposal and re-use for anything that leaves: a decommissioned facility tablet, a developer laptop, a phone sold on.',
 'InkTree', 'the first real record', DATE '2026-09-18');

CREATE VIEW administrative_gaps AS
SELECT id, requirement, owner, required_before, status
FROM administrative_controls WHERE status <> 'in_effect'
ORDER BY required_before, id;

COMMENT ON VIEW administrative_gaps IS
  'Expected to have rows, and today it has all of them. This is the honest half of the
   package: everything here is required, none of it is built, and each line says who owns
   it and what it blocks. A reviewer reading only this view learns more about what is
   missing than from any paragraph.';

CREATE VIEW administrative_unowned AS
SELECT id, requirement FROM administrative_controls
WHERE btrim(owner) = '' OR btrim(required_before) = '';

COMMENT ON VIEW administrative_unowned IS
  'Must be empty. The same rule the vendor register applies: a gap is allowed, a gap with
   nobody''s name on it is not.';
