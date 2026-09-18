-- Incidents, breaches, and telling the facility
--
-- Applied after agreements.sql, which holds the window each agreement sets.
--
-- The word "breach" appeared twice in this package, both times in a comment, and
-- "incident" three times in passing. monitoring_signals says what is watched and who is
-- paged, and then the paged engineer finds that a denial spike was somebody reaching for
-- records that were not theirs, and there is nowhere to write it down.
--
-- What the rule wants from that moment is specific. A record of the incident. A
-- four-factor assessment of whether it is a breach: what was involved, who received it,
-- whether it was actually acquired or viewed, and how far it has been mitigated. And if it
-- is, notification to the covered entity without unreasonable delay and within sixty days,
-- with the identity of every affected individual. The business associate carries the burden
-- of proving it did so.
--
-- So the four factors are columns that must be filled before a conclusion may be recorded,
-- and the clock is a view that has to be empty.

CREATE TYPE incident_conclusion AS ENUM ('not_a_breach', 'breach');

CREATE TABLE security_incidents (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  discovered_at   timestamptz NOT NULL,
  discovered_by   text NOT NULL,
  summary         text NOT NULL,

  -- §164.402(2). All four, or no conclusion.
  f1_nature       text,   -- what was involved, and how identifying it is
  f2_recipient    text,   -- who it went to, and what obligations they are under
  f3_acquired     text,   -- whether it was actually acquired or viewed
  f4_mitigated    text,   -- how far the risk has been reduced

  conclusion      incident_conclusion,
  concluded_at    timestamptz,
  concluded_by    text,

  -- The trail is not a place for the record itself, and neither is this.
  carries_phi     boolean NOT NULL DEFAULT false,
  note            text,

  CONSTRAINT incident_carries_no_phi CHECK (NOT carries_phi),

  CONSTRAINT all_four_factors_before_a_conclusion CHECK (
    conclusion IS NULL OR (
      f1_nature IS NOT NULL AND f2_recipient IS NOT NULL
      AND f3_acquired IS NOT NULL AND f4_mitigated IS NOT NULL)),

  CONSTRAINT a_conclusion_has_a_date_and_a_name CHECK (
    (conclusion IS NULL) = (concluded_at IS NULL)
    AND (conclusion IS NULL) = (concluded_by IS NULL))
);

COMMENT ON CONSTRAINT all_four_factors_before_a_conclusion ON security_incidents IS
  'The four factors are not a form to fill in afterwards. A conclusion of "not a breach"
   reached without them is the conclusion the rule presumes against - §164.402 says a
   disclosure is a breach unless the assessment shows a low probability of compromise, so
   the assessment is the thing that makes the answer available at all.';

COMMENT ON COLUMN security_incidents.summary IS
  'What happened, in enough words for somebody to understand it a year later. Not what the
   record said: an incident log that quotes the disclosure has made a second copy of it.';


CREATE TABLE breach_notifications (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  incident_id     uuid NOT NULL REFERENCES security_incidents(id) ON DELETE RESTRICT,
  facility_id     uuid NOT NULL REFERENCES facilities(id) ON DELETE RESTRICT,

  notified_at     timestamptz NOT NULL,
  notified_whom   text NOT NULL,   -- the contact on the agreement, as it was at the time
  method          text NOT NULL,
  individuals     integer NOT NULL,
  content_note    text NOT NULL,   -- that §164.410(c) was covered, not the content itself

  UNIQUE (incident_id, facility_id),
  CHECK (individuals >= 0)
);

COMMENT ON TABLE breach_notifications IS
  'One row per affected facility, because the obligation is to each covered entity
   separately. §164.414 puts the burden of proof on the business associate, and this is
   what discharges it: who was told, by what means, when, and how many people it concerned.';


-- ════════════════════════════════════════════════════════════════════ the clock

CREATE OR REPLACE FUNCTION notification_deadline(target_incident uuid, target_facility uuid)
RETURNS timestamptz LANGUAGE sql STABLE
  SET search_path = pg_catalog, public AS $$
  SELECT si.discovered_at + make_interval(days => coalesce(
           (SELECT min(fa.notification_days) FROM facility_agreements fa
            WHERE fa.facility_id = target_facility AND fa.terminated_on IS NULL),
           60))
  FROM security_incidents si WHERE si.id = target_incident
$$;

COMMENT ON FUNCTION notification_deadline(uuid, uuid) IS
  'The agreement''s window, or the rule''s sixty days where there is no agreement to read.
   Whichever is shorter, because an agreement may ask for faster and may not ask for
   slower - which the constraint on facility_agreements already refuses.';


CREATE VIEW notifications_overdue AS
SELECT si.id AS incident_id, f.id AS facility_id, f.name AS facility,
       si.discovered_at, notification_deadline(si.id, f.id) AS due
FROM security_incidents si
CROSS JOIN facilities f
WHERE si.conclusion = 'breach'
  AND EXISTS (SELECT 1 FROM residents r WHERE r.facility_id = f.id)
  AND NOT EXISTS (SELECT 1 FROM breach_notifications bn
                  WHERE bn.incident_id = si.id AND bn.facility_id = f.id)
  AND notification_deadline(si.id, f.id) < now();

COMMENT ON VIEW notifications_overdue IS
  'Must be empty. A facility with residents, a breach concluded, and nobody told inside the
   window the agreement set.';

CREATE VIEW notifications_late AS
SELECT bn.incident_id, bn.facility_id, bn.notified_at,
       notification_deadline(bn.incident_id, bn.facility_id) AS due,
       bn.notified_at - notification_deadline(bn.incident_id, bn.facility_id) AS by
FROM breach_notifications bn
WHERE bn.notified_at > notification_deadline(bn.incident_id, bn.facility_id);

COMMENT ON VIEW notifications_late IS
  'Not required to be empty, deliberately. A notification sent late is still a notification
   and the record of it has to survive; refusing the row would leave nothing to show. This
   is what a reviewer reads and what an incident review starts from.';

CREATE VIEW incidents_unassessed AS
SELECT id, discovered_at, summary FROM security_incidents
WHERE conclusion IS NULL AND discovered_at < now() - interval '7 days';

COMMENT ON VIEW incidents_unassessed IS
  'Must be empty. An incident nobody concluded is not a low-risk incident; it is one the
   clock is running on, and the clock started when it was discovered.';


DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dailycare_app') THEN
    REVOKE ALL ON security_incidents, breach_notifications FROM dailycare_app;
  END IF;
END $$;
