-- Third parties
--
-- Applied after environments.sql.
--
-- The vendor list is the part of a compliance package most likely to be true on the day it
-- is written and wrong three months later. It is also the part where being wrong is not a
-- documentation problem: a company that holds protected health information without an
-- agreement in place is the finding, not the missing paragraph.
--
-- So it is a table with the same discipline as the classification — and one addition that
-- matters more than the list itself.
--
-- A vendor that holds PHI is the easy case. Everyone remembers the database and the bucket.
-- The case that gets missed is the vendor that does not hold PHI but *could receive it*:
-- the logging service that gets whatever a careless error message happened to include, the
-- crash reporter that ships the state a screen was in, the support inbox somebody forwards
-- a screenshot to. Those are not contract problems. A signed agreement does not stop a
-- stack trace containing a resident's name — a control does. So exposure is recorded as
-- four kinds, and anything that could receive PHI must name the control that stops it.
--
-- One more thing this file deliberately does not do: it does not refuse to record an
-- uncomfortable answer. A register that only accepts good news stops being used the first
-- week it would have said something useful. Gaps are allowed and expected. What is not
-- allowed is a gap with nobody's name on it, or a vendor already receiving live data
-- without an agreement — and those are the two things the views below look for.


CREATE TYPE vendor_role AS ENUM (
  'processor',     -- runs part of the system on our behalf
  'data_source',   -- sends us records that originate in their system
  'conduit',       -- carries a message without being the place it lives
  'subprocessor'   -- reached through another vendor rather than directly
);

CREATE TYPE baa_state AS ENUM (
  'signed',
  'offered_not_signed',   -- available, not executed yet. The common honest answer.
  'not_offered',          -- the vendor does not sign one. Decides the vendor, usually.
  'not_required'          -- nothing they touch is PHI, argued in the note
);

CREATE TYPE exposure AS ENUM (
  'holds',          -- the data lives there
  'transits',       -- passes through, is not retained
  'could_receive',  -- only by accident, which is why a control is required
  'none'
);


CREATE TABLE vendors (
  id              text PRIMARY KEY,
  name            text NOT NULL,
  purpose         text NOT NULL,
  role            vendor_role NOT NULL,

  -- Whether this vendor is carrying real data today. The difference between a plan and a
  -- problem.
  live            boolean NOT NULL DEFAULT false,

  baa             baa_state NOT NULL,
  baa_signed_on   date,
  covered_scope   text,        -- which of the vendor's products the agreement covers

  -- Only meaningful while there is a gap. Who is closing it, by when, and what is in the
  -- way. A gap with none of these is an unowned one.
  gap_owner       text,
  gap_required_before text,
  gap_blocker     text,

  note            text,
  reviewed_on     date NOT NULL,
  CHECK (baa <> 'signed' OR baa_signed_on IS NOT NULL)
);

CREATE TABLE vendor_exposure (
  vendor_id  text NOT NULL REFERENCES vendors(id) ON DELETE CASCADE,
  class      data_class NOT NULL,
  exposure   exposure NOT NULL,
  -- What stops an accident becoming a holding. Required exactly where it matters.
  control    text,
  note       text,
  PRIMARY KEY (vendor_id, class),
  CHECK (exposure <> 'could_receive' OR control IS NOT NULL)
);

COMMENT ON CONSTRAINT vendor_exposure_check ON vendor_exposure IS
  'A vendor that could receive PHI by accident is not made safe by an agreement. Naming the
   control is the point of recording the exposure at all.';


-- ── the infrastructure ─────────────────────────────────────────────────────────

INSERT INTO vendors (id, name, purpose, role, live, baa, baa_signed_on, covered_scope,
                     note, reviewed_on) VALUES
('gcp', 'Google Cloud Platform',
 'Cloud Run for the API, Cloud SQL for PostgreSQL, Cloud Storage for photographs, Secret Manager for credentials, Cloud Logging, Artifact Registry.',
 'processor', false, 'signed', DATE '2026-09-10',
 'Only the products on Google''s HIPAA Included Products list are in scope. Anything used outside that list is outside the agreement, whatever else the contract says, and the list is worth rereading when a new service is adopted.',
 'Accepted in the console by the billing account owner. Signed before the project exists, which is the right order: the alternative is a window where something is deployed and not covered.',
 DATE '2026-09-15');

INSERT INTO vendor_exposure (vendor_id, class, exposure, control, note) VALUES
('gcp','phi','holds',NULL,'Cloud SQL and Cloud Storage. This is where the record lives.'),
('gcp','identifying','holds',NULL,'Staff and family accounts.'),
('gcp','secret','holds','Secret Manager, never the repository and never an environment variable baked into an image.',NULL),
('gcp','operational','holds',NULL,NULL);

-- Logging is the accident, and it is a separate entry because it is a separate problem.
INSERT INTO vendors (id, name, purpose, role, live, baa, covered_scope,
                     gap_owner, gap_required_before, gap_blocker, note, reviewed_on,
                     baa_signed_on) VALUES
('gcp-logging', 'Google Cloud Logging',
 'Application and request logs.',
 'subprocessor', false, 'signed',
 'Covered by the same agreement as the platform.',
 NULL, NULL, NULL,
 'Listed separately because the agreement is not the control. A log line is written by our code, and no contract stops one from containing a resident name.',
 DATE '2026-09-15', DATE '2026-09-10');

INSERT INTO vendor_exposure (vendor_id, class, exposure, control, note) VALUES
('gcp-logging','phi','could_receive',
 'Logs carry the resident uuid and never the name, the note, or any clinical field. Errors returned to a client are identifiers and codes. The audit trail, which does record who read what, is a table in the database and is not written to the log stream.',
 'The realistic failure is a stack trace or an exception message that happens to include a row.'),
('gcp-logging','identifying','could_receive',
 'The same rule. A request log records the user uuid, never the email address.',NULL),
('gcp-logging','operational','holds',NULL,NULL);


-- ── the clinical system ────────────────────────────────────────────────────────

INSERT INTO vendors (id, name, purpose, role, live, baa, gap_owner, gap_required_before,
                     gap_blocker, note, reviewed_on) VALUES
('pointclickcare', 'PointClickCare',
 'Medication administration records for facilities that already use it, read into medication_events with source = pointclickcare.',
 'data_source', false, 'not_offered',
 'the facility', 'the first facility connects its clinical system',
 'No facility has asked for the integration yet.',
 'The relationship runs the other way from the rest of this list: their system is the source and the facility is their customer. What DailyCare needs is the facility''s authorisation to receive the records, not an agreement with the vendor. Recorded here because a reviewer will ask where medication data comes from, and because the schema already has a column saying it came from them.',
 DATE '2026-09-15');

INSERT INTO vendor_exposure (vendor_id, class, exposure, control, note) VALUES
('pointclickcare','phi','holds',NULL,'Their record, their retention. DailyCare receives a copy and applies its own.'),
('pointclickcare','operational','transits',NULL,NULL);


-- ── messaging ──────────────────────────────────────────────────────────────────
-- The design decision is the control. A notification that named the resident, or said
-- anything about their day, would put a health fact into a third party's message logs and
-- onto a lock screen in a room with other people in it.

INSERT INTO vendors (id, name, purpose, role, live, baa, gap_owner, gap_required_before,
                     gap_blocker, note, reviewed_on) VALUES
('twilio', 'Twilio',
 'SMS for invitations and sign-in codes.',
 'conduit', false, 'offered_not_signed',
 'InkTree', 'the first invitation is sent to a real number',
 'No account yet; the messaging path is not built.',
 'In scope for identifying data because a phone number identifies a person. Out of scope for PHI by design rather than by contract.',
 DATE '2026-09-15');

INSERT INTO vendor_exposure (vendor_id, class, exposure, control, note) VALUES
('twilio','phi','could_receive',
 'A message body is a fixed string with no resident name, no facility name and nothing clinical: "You have a new update in DailyCare." The variable part is a link and a code.',
 'The tempting version of this feature - "Cathy had a difficult night" - is the one that puts a health fact on a lock screen.'),
('twilio','identifying','transits','Phone number and message body only. No account is created on their side.',NULL);


-- ── build and distribution ─────────────────────────────────────────────────────

INSERT INTO vendors (id, name, purpose, role, live, baa, note, reviewed_on) VALUES
('expo', 'Expo Application Services',
 'Builds the iOS and Android binaries and signs them.',
 'processor', true, 'not_required',
 'Receives source code and signing credentials. It never receives a record: the build has no database connection and the app ships with no data in it.',
 DATE '2026-09-15'),
('appstores', 'Apple App Store and Google Play',
 'Distribution of the application binary.',
 'conduit', true, 'not_required',
 'A binary is not a record. Crash reports collected by the platforms are the one thing to watch, and they are covered by the logging rule rather than by an agreement.',
 DATE '2026-09-15'),
('stripe', 'Stripe',
 'Facility subscription billing.',
 'processor', false, 'not_required',
 'The customer is a building, not a resident. Nothing sent to them is about a person in care; a resident count is a number.',
 DATE '2026-09-15');

INSERT INTO vendor_exposure (vendor_id, class, exposure, control, note) VALUES
('expo','phi','none',NULL,NULL),
('expo','secret','holds','Signing keys held in EAS credentials. Separate from every runtime secret, which is in Secret Manager.',NULL),
('expo','operational','holds',NULL,'Build metadata.'),
('appstores','phi','could_receive',
 'Platform crash reporting is left at its default, which sends a stack trace and no application state. No custom crash payload is attached, and nothing that renders a resident record catches an exception into a report.',
 NULL),
('appstores','operational','holds',NULL,NULL),
('stripe','phi','none',NULL,NULL),
('stripe','identifying','holds',NULL,'A billing contact at the facility, who is staff.'),
('stripe','operational','holds',NULL,NULL);


-- ════════════════════════════════════════════════════════════════════ the questions
--
-- Three views, and the difference between them is what makes the register usable. The
-- first is expected to return rows. The other two must not.

CREATE VIEW phi_vendors AS
SELECT v.id, v.name, v.role, v.live, v.baa, ve.exposure, ve.note
FROM vendors v
JOIN vendor_exposure ve ON ve.vendor_id = v.id
WHERE ve.class = 'phi' AND ve.exposure IN ('holds', 'transits')
ORDER BY v.live DESC, v.id;

COMMENT ON VIEW phi_vendors IS
  'The inventory a reviewer asks for. Everyone who holds or carries a resident record.';

CREATE VIEW vendor_gaps AS
SELECT v.id, v.name, v.baa, v.live, v.gap_owner, v.gap_required_before, v.gap_blocker
FROM vendors v
WHERE v.baa NOT IN ('signed', 'not_required')
  AND EXISTS (SELECT 1 FROM vendor_exposure ve
              WHERE ve.vendor_id = v.id AND ve.class = 'phi'
                AND ve.exposure <> 'none')
ORDER BY v.live DESC, v.id;

COMMENT ON VIEW vendor_gaps IS
  'Expected to have rows, and today it does. A compliance register that could not hold an
   uncomfortable answer would stop being used the first week it had one to hold.
   Deliberately includes vendors that could only receive PHI by accident: an accident
   inside an agreement is a different conversation from one outside it.';

CREATE VIEW unacknowledged_gaps AS
SELECT id, name, baa FROM vendor_gaps
WHERE gap_owner IS NULL OR gap_required_before IS NULL OR gap_blocker IS NULL;

COMMENT ON VIEW unacknowledged_gaps IS
  'Must be empty. A gap is acceptable. A gap with nobody''s name on it, no date and no
   stated reason is the one that is still open a year later.';

CREATE VIEW live_without_agreement AS
SELECT v.id, v.name, v.baa, ve.exposure
FROM vendors v
JOIN vendor_exposure ve ON ve.vendor_id = v.id
WHERE v.live
  AND ve.class = 'phi' AND ve.exposure IN ('holds', 'transits')
  AND v.baa NOT IN ('signed', 'not_required');

COMMENT ON VIEW live_without_agreement IS
  'Must be empty, and this is the one that protects somebody rather than documenting them.
   A vendor carrying real records without an agreement is the finding itself.';

-- Two completeness checks. The register is only as good as the question it was asked, and
-- the question is asked per vendor.

CREATE VIEW vendors_without_phi_answer AS
SELECT v.id, v.name FROM vendors v
WHERE NOT EXISTS (SELECT 1 FROM vendor_exposure ve
                  WHERE ve.vendor_id = v.id AND ve.class = 'phi');

COMMENT ON VIEW vendors_without_phi_answer IS
  'Must be empty. A vendor in the register with nothing recorded about PHI has not been
   assessed; it has been listed. "none" is an answer and belongs in the table.';

CREATE VIEW stale_reviews AS
SELECT id, name, reviewed_on, current_date - reviewed_on AS days_ago
FROM vendors WHERE reviewed_on < current_date - 365
ORDER BY reviewed_on;

COMMENT ON VIEW stale_reviews IS
  'Must be empty. The failure mode of a vendor register is not that it was wrong when it
   was written; it is that nobody read it again. A row here means someone has to.';

CREATE VIEW uncontrolled_exposure AS
SELECT ve.vendor_id, v.name, ve.class, ve.exposure
FROM vendor_exposure ve JOIN vendors v ON v.id = ve.vendor_id
WHERE ve.exposure = 'could_receive' AND ve.control IS NULL;

COMMENT ON VIEW uncontrolled_exposure IS
  'Must be empty, and is kept empty by a constraint rather than by this view noticing. Here
   so the reviewer can see the answer is zero without reading the constraint.';


-- ════════════════════════════════════════════════════════════════════ privileges
--
-- The register is not application data. It is read by whoever is answering the reviewer.

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dailycare_app') THEN
    REVOKE ALL ON vendors, vendor_exposure FROM dailycare_app;
  END IF;
END $$;
