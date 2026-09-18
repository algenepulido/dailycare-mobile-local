-- The agreement that reaches this system from above
--
-- Applied after schema.sql, before access-policies.sql.
--
-- The package models every agreement that flows down - Google, Twilio, the clinical system
-- - with some discipline, and modelled nothing about the one that flows up. A facility
-- could be created and a resident admitted into it with no business associate agreement in
-- place. The vendor register would have said every downstream agreement was signed and
-- been right, while the record itself was held under no contract at all.
--
-- That is not a documentation gap. A business associate holding protected health
-- information for a covered entity without an agreement is the finding, and this package
-- already says exactly that about the other direction.
--
-- So admission is the gate: a resident cannot be admitted into a facility that has no
-- executed agreement, and the refusal is row-level security rather than a review comment.

CREATE TABLE facility_agreements (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  facility_id    uuid NOT NULL REFERENCES facilities(id) ON DELETE RESTRICT,

  executed_on    date NOT NULL,
  terminated_on  date,

  -- §164.410 requires notifying the covered entity of a breach. Whom, and how fast - the
  -- agreement may set a window shorter than the rule's sixty days, and usually does.
  notification_contact text NOT NULL,
  notification_days    integer NOT NULL DEFAULT 60,

  counterparty   text NOT NULL,     -- who signed, on the facility's side
  note           text,

  CHECK (notification_days > 0 AND notification_days <= 60),
  CHECK (terminated_on IS NULL OR terminated_on >= executed_on)
);

CREATE INDEX ON facility_agreements (facility_id) WHERE terminated_on IS NULL;

COMMENT ON TABLE facility_agreements IS
  'One row per facility per agreement. Sixty days is the rule''s outer limit, so the
   constraint refuses a longer window: an agreement cannot give away a deadline the rule
   sets. A shorter one is the facility''s to ask for and is honoured.';


CREATE OR REPLACE FUNCTION facility_is_covered(target_facility uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = pg_catalog, public AS $$
  SELECT EXISTS (
    SELECT 1 FROM facility_agreements fa
    WHERE fa.facility_id   = target_facility
      AND fa.executed_on  <= current_date
      AND fa.terminated_on IS NULL
  )
$$;

COMMENT ON FUNCTION facility_is_covered(uuid) IS
  'Consulted by the policy that admits a resident. An agreement dated in the future does
   not cover today, and a terminated one does not cover anything.';


-- ════════════════════════════════════════════════════════════════════ the questions

CREATE VIEW facilities_without_agreement AS
SELECT f.id, f.name
FROM facilities f
WHERE NOT facility_is_covered(f.id);

COMMENT ON VIEW facilities_without_agreement IS
  'Expected to have rows while a facility is being set up, and it is the row above the one
   that matters. A building with no agreement and no residents is a sales conversation.';

CREATE VIEW residents_without_agreement AS
SELECT r.id AS resident_id, r.facility_id, f.name AS facility
FROM residents r
JOIN facilities f ON f.id = r.facility_id
WHERE NOT facility_is_covered(r.facility_id);

COMMENT ON VIEW residents_without_agreement IS
  'Must be empty. A record held for a covered entity with no contract covering it is the
   finding itself. Admission is refused, so the only way a row appears here is an agreement
   terminated while residents are still inside - which is a real situation, and is why this
   is a view rather than only a constraint.';

CREATE VIEW agreements_expiring_with_residents AS
SELECT fa.facility_id, f.name AS facility, fa.terminated_on,
       (SELECT count(*) FROM residents r
        WHERE r.facility_id = fa.facility_id AND r.departed_on IS NULL) AS residents_inside
FROM facility_agreements fa
JOIN facilities f ON f.id = fa.facility_id
WHERE fa.terminated_on IS NOT NULL
  AND EXISTS (SELECT 1 FROM residents r
              WHERE r.facility_id = fa.facility_id AND r.departed_on IS NULL);

COMMENT ON VIEW agreements_expiring_with_residents IS
  'The situation the rule cares about most and nothing else here would notice: the contract
   has ended and the records have not gone anywhere. Somebody has to decide whether they
   are returned, destroyed, or covered by a new agreement, and §164.504(e)(2)(ii)(J) says
   which.';
