-- Row-level security on the tables that say who people are
--
-- Applied after access-policies.sql.
--
-- Nine tables force row-level security and twenty-five do not, and the twenty-five include
-- users, facility_members, assignments, sessions, user_tokens, facilities and the audit
-- trail. That was not an oversight about unimportant tables. The application must be able
-- to read users to sign anybody in, and the moment it can, it can read every staff and
-- family email and display name at every facility, every session row, every token digest
-- and every assignment - with nothing in the database narrowing it to one building.
--
-- The access matrix did not notice because access_matrix_uncovered_tables asked only about
-- tables with a phi column, and these are classified identifying. A caregiver's email is
-- not PHI. A list of every family member granted access to a resident in memory care,
-- across every customer, is the kind of thing breach notification is written about.
--
-- ENABLE rather than FORCE here, and the difference matters. The membership helpers run as
-- the definer and read facility_members; a forced policy on facility_members that consults
-- one of them is a policy reading its own table, which PostgreSQL refuses as recursion.
-- FORCE existed on the PHI tables to guard against the application connecting as the owner.
-- That is guarded directly instead, by app_owns_nothing in grants.sql, which is a better
-- check than a flag: it asks the question rather than assuming the answer.


-- ════════════════════════════════════════════════════════════════════ who is a colleague

-- The facilities this session belongs to. A definer function rather than a subquery,
-- because a policy on facility_members whose condition reads facility_members applies
-- itself to its own subquery and PostgreSQL stops it as recursion. ENABLE rather than
-- FORCE is not enough on its own: the owner bypasses, the application does not, and the
-- application is who evaluates the policy.
CREATE OR REPLACE FUNCTION app_my_facilities() RETURNS SETOF uuid
LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = pg_catalog, public AS $$
  SELECT fm.facility_id FROM facility_members fm
  WHERE fm.user_id = app_user_id()
    AND fm.state = 'active' AND fm.ended_at IS NULL
$$;

CREATE OR REPLACE FUNCTION app_my_contact_facilities() RETURNS SETOF uuid
LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = pg_catalog, public AS $$
  SELECT rc.facility_id FROM resident_contacts rc
  WHERE rc.user_id = app_user_id() AND rc.state = 'active'
$$;

CREATE OR REPLACE FUNCTION app_shares_a_facility(target_user uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = pg_catalog, public AS $$
  SELECT EXISTS (
    SELECT 1
    FROM facility_members me
    JOIN facility_members them ON them.facility_id = me.facility_id
    WHERE me.user_id   = app_user_id()
      AND me.state     = 'active' AND me.ended_at IS NULL
      AND them.user_id = target_user
  )
$$;

COMMENT ON FUNCTION app_shares_a_facility(uuid) IS
  'A caregiver has to be able to see that a day was filed by Maria. Colleagues at the same
   building, and nobody at another one.';

CREATE OR REPLACE FUNCTION app_manages_a_contact_of(target_user uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = pg_catalog, public AS $$
  SELECT EXISTS (
    SELECT 1
    FROM resident_contacts rc
    JOIN facility_members fm ON fm.facility_id = rc.facility_id
    WHERE rc.user_id    = target_user
      AND fm.user_id    = app_user_id()
      AND fm.role       = 'care_manager'
      AND fm.state      = 'active' AND fm.ended_at IS NULL
  )
$$;

COMMENT ON FUNCTION app_manages_a_contact_of(uuid) IS
  'A care manager grants and withdraws family access, so they see the family they granted
   it to. A caregiver does not: they file care, and the family list is not theirs.';


-- ════════════════════════════════════════════════════════════════════ people

ALTER TABLE users ENABLE ROW LEVEL SECURITY;

CREATE POLICY users_self ON users FOR SELECT
  USING (id = app_user_id());

CREATE POLICY users_colleagues ON users FOR SELECT
  USING (app_shares_a_facility(id));

CREATE POLICY users_family_of_my_facility ON users FOR SELECT
  USING (app_manages_a_contact_of(id));

-- A person may correct their own display name. Nobody edits anybody else through the
-- application: creating and deactivating an account is an administrative act, and the
-- reject_record_rewrite pattern would be the way to narrow it further when there is an
-- admin surface to narrow.
CREATE POLICY users_update_self ON users FOR UPDATE
  USING (id = app_user_id()) WITH CHECK (id = app_user_id());

COMMENT ON POLICY users_self ON users IS
  'Three read policies rather than one expression, because they are three different
   reasons: myself, a colleague at my building, and - for a manager only - a family member
   I granted access to.';


-- ════════════════════════════════════════════════════════════════════ membership

ALTER TABLE facility_members ENABLE ROW LEVEL SECURITY;

CREATE POLICY members_own_facilities ON facility_members FOR SELECT
  USING (facility_id IN (SELECT app_my_facilities()));

COMMENT ON POLICY members_own_facilities ON facility_members IS
  'Through a function rather than a subquery on this same table, which recurses. The first
   version of this file was written as a subquery and PostgreSQL refused it immediately,
   which is the useful kind of refusal.';

-- Membership is granted and ended by an administrator, not through a request. No insert,
-- update or delete policy exists for the application on this table.


ALTER TABLE assignments ENABLE ROW LEVEL SECURITY;

CREATE POLICY assignments_own_facilities ON assignments FOR SELECT
  USING (facility_id IN (SELECT app_my_facilities()));

CREATE POLICY assignments_manager_writes ON assignments FOR INSERT
  WITH CHECK (app_is_care_manager(facility_id));

CREATE POLICY assignments_manager_ends ON assignments FOR UPDATE
  USING      (app_is_care_manager(facility_id))
  WITH CHECK (app_is_care_manager(facility_id));

-- The retention role's policies on this table are in retention.sql, next to the function
-- they depend on and the rest of that role's reach.


-- ════════════════════════════════════════════════════════════════════ buildings

ALTER TABLE facilities ENABLE ROW LEVEL SECURITY;

CREATE POLICY facilities_mine ON facilities FOR SELECT
  USING (id IN (SELECT app_my_facilities())
      OR id IN (SELECT app_my_contact_facilities()));

COMMENT ON POLICY facilities_mine ON facilities IS
  'A family member sees the name of the building their mother is in, and no other. Without
   this the application could list every customer, which is a competitive fact as well as a
   privacy one.';


ALTER TABLE retention_policies ENABLE ROW LEVEL SECURITY;

CREATE POLICY retention_policies_manager ON retention_policies FOR SELECT
  USING (app_is_care_manager(facility_id));

-- Retention needs to read every policy, and runs as its own role.
CREATE POLICY retention_policies_job ON retention_policies FOR SELECT
  TO dailycare_retention USING (true);


-- ════════════════════════════════════════════════════════════════════ the trail

ALTER TABLE audit_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY audit_events_manager ON audit_events FOR SELECT
  USING (app_is_care_manager(facility_id));

COMMENT ON POLICY audit_events_manager ON audit_events IS
  'Who saw a resident''s record is a question a facility asks about its own building. A
   caregiver does not read the trail; a family member does not either, though the facility
   owes them an accounting of disclosures and would produce it from here.';

CREATE POLICY audit_events_retention ON audit_events FOR ALL
  TO dailycare_retention USING (true) WITH CHECK (true);


-- ════════════════════════════════════════════════════════════════════ credentials
--
-- No policy at all for the application. Row-level security with no policy denies
-- everything, which is the intent: the functions in authentication.sql run as the definer
-- and are the only way in or out. A session row is a credential, and the application
-- handling credentials by hand is the thing being prevented.

ALTER TABLE sessions    ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_tokens ENABLE ROW LEVEL SECURITY;

-- Except this: a person may see the devices they are signed in on, which is how they
-- notice one they do not recognise.
CREATE POLICY sessions_mine ON sessions FOR SELECT
  USING (user_id = app_user_id());

COMMENT ON POLICY sessions_mine ON sessions IS
  'Deliberately SELECT only, and deliberately the only policy on this table. Revoking is
   revoke_session(), which is a function the application calls rather than an UPDATE it
   composes.';
