-- Changes to the model made for the care history and the audit trail.
--
-- A separate file rather than an edit to identity-policies.sql, because migrate.sh pins
-- every applied file by digest and refuses a file that changed after it went into a
-- database. That rule is the reason dev and staging can be trusted to hold the model they
-- say they hold, so the answer is a new file, not a way around it.
--
-- Everything here is written to be correct twice: applied to a database built from the
-- model a moment ago, and applied to one that has been running since September. A forward
-- change that only works on one of those is how the two drift apart.


-- ════════════════════════════════════════════════════════════════════ the trail
--
-- identity-policies.sql enabled row-level security on audit_events and gave a care manager
-- a read policy over their own facility. ENABLE exempts the table owner, and the owner is
-- who audit_phi_write() and audit_read() run as - both are SECURITY DEFINER. So the read
-- policy applied to everybody except the one role that could read every facility's trail
-- in a single statement.
--
-- That was tolerable while nothing read the table. The history work serves the trail to a
-- client, so it stops being tolerable now.

ALTER TABLE audit_events FORCE ROW LEVEL SECURITY;

-- FORCE also applies to the definer functions, which is the part that bites. Without a
-- policy admitting their INSERT, forcing the table does not harden the trail - it stops
-- the trail being written, and every read by the application raises instead of recording.
--
-- Permissive on purpose. What keeps the application out of this table is the INSERT
-- privilege it does not hold, revoked in audit-logging.sql, and that has always been where
-- the boundary lived. A policy was never what kept it out. This says only that a row
-- arriving by the definer path is allowed to land. Read alone it looks like an opening;
-- read with the REVOKE it is not one.
DROP POLICY IF EXISTS audit_events_write ON audit_events;
CREATE POLICY audit_events_write ON audit_events FOR INSERT
  WITH CHECK (true);

COMMENT ON POLICY audit_events_write ON audit_events IS
  'Permissive on purpose. The application is held out of this table by the INSERT privilege
   it does not hold - see the REVOKE in audit-logging.sql - not by this policy, which exists
   so that FORCE does not silence the definer functions that write the trail.';

-- Declared, so row_security_drift covers it from now on. Without this the view reads a
-- forced table it was never told about as drift in the other direction.
INSERT INTO forced_row_security (table_name, why) VALUES
  ('audit_events', 'Who read whose record. The definer functions that write it run as the owner.')
ON CONFLICT (table_name) DO NOTHING;
