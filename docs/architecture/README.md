# Architecture

The data model, the access model, and the classification the review package is generated
from. Milestone 2 work, kept as SQL rather than as prose because a description of a
constraint and a constraint are different things, and only one of them stops a mistake.

## The files

| | |
|---|---|
| `roles.sql` | The three application roles plus the export role. Applied first, and the only file needing the privilege to create a role. |
| `schema.sql` | The production schema. 15 tables, 12 enums. Applied first. |
| `schema-invariants.sql` | The guarantees the schema makes, written as the smallest statements that prove them. Self-reporting. Includes what a credential column will and will not accept. |
| `access-policies.sql` | The three roles as row-level security. Applied after the schema. |
| `access-invariants.sql` | Attempts to reach things that should be unreachable. Runs as a non-superuser, because a superuser bypasses row-level security and would report that everything works. |
| `architecture-diagram.md` | The four diagrams: what the pieces are, where a resident's record exists, one request end to end, and the one flow that leaves the database. |
| `authentication.sql` | Sessions, refresh rotation and single-use tokens. What could be moved out of a handler and into the database. |
| `auth-invariants.sql` | Including the milestone's own acceptance criteria: reinstall and sign back in, and two authorised devices. |
| `agreements.sql` | The agreement that has to be in place before a resident is admitted, and what happens when one ends with residents inside. |
| `incidents.sql` | Somewhere to record an incident, the four factors that make a conclusion possible, and a clock that runs. |
| `incident-invariants.sql` | One incident walked from discovery to notification, with the clock moved back at each step. |
| `identity-policies.sql` | Row-level security on the tables that say who people are, which nine PHI tables had and twenty-five others did not. |
| `grants.sql` | What the application is granted, as a table, applied from it and compared to the catalogue both ways. |
| `access-matrix.sql` | The role and access-control matrix as a table, checked against the catalogue it describes. |
| `data-classification.sql` | Which columns hold PHI, and the views that generate the inventory from it. |
| `audit-logging.sql` | Triggers that record every write to a PHI table, and the coverage views that find a table without one. |
| `audit-invariants.sql` | Including the canary: a care note written with a unique string, then every column of every audit row searched for it. |
| `retention.sql` | When a record is destroyed, who is allowed to destroy it, and the handshake with object storage. |
| `retention-invariants.sql` | Counts rows in the tables themselves after a retention run, because a soft delete would pass a test that only asked the API. |
| `environments.sql` | How a production snapshot becomes a database a developer may hold: what is replaced, what is deliberately kept, and the two locks that stop it running anywhere near production. |
| `environment-invariants.sql` | Plants a unique string in every sensitive field, scrubs, then searches every column of every table for all of them. |
| `vendors.sql` | Who else touches the data, what they touch, and which agreements are not in place yet. |
| `vendor-invariants.sql` | Moves the register into each bad state in turn and asks whether anything noticed. |
| `backup-recovery.sql` | What is backed up, for how long, who may restore it, and the record of somebody having done so. |
| `backup-invariants.sql` | Mostly the restore gate: a database that finds itself somewhere other than where it was written serves nothing until it has been scrubbed. |
| `phi-safe-logging.sql` | What a log line may not contain, what a notification may say, and what is watched. Generated from the classification rather than remembered. |
| `logging-invariants.sql` | Including the notification somebody will ask for — the one that names a resident — being refused. |
| `boundary.sql` | The InkTree boundary: which way content may cross, what a reversal would require, and the two ways it gets crossed by accident. |
| `boundary-invariants.sql` | Breaks the boundary four plausible ways and asks whether anything noticed. |
| `encryption-and-secrets.sql` | Where every secret lives, what is kept instead of it, and what is encrypted — including the two controls that were declined and why. |
| `secrets-invariants.sql` | Mostly negative controls: a credential in the repository, one baked into an image, one nobody said anything about. |
| `checks-support.sql` | Not part of the model. What lets a suite give the same answers to a superuser and to a managed-instance owner. |
| `review.sh` | The whole thing in one command, in a throwaway container, for a reviewer with nothing installed but Docker. |
| `verify.sh` | Runs every suite, each in its own database, and exits non-zero if anything failed. |
| `restore-drill.sh` | The drill itself. Dumps a database, restores it under another name, and checks both halves — that the records came back, and that the copy refuses to hand them out. |
| `inktree-alignment.md` | Where this model meets the InkTree field guide and where it does not, and the one difference that is a boundary rather than a preference. |

## Verifying it

Everything below runs against scratch databases and leaves nothing behind. PostgreSQL 14
or newer.

With nothing installed but Docker, and nothing left behind:

```bash
./review.sh
```

That starts a throwaway PostgreSQL 14, runs everything inside it as an ordinary database
user, and removes the container. It runs as an ordinary user rather than as a superuser
deliberately — see below.

With your own PostgreSQL:

```bash
./verify.sh                  # 420 checks across twelve suites
./restore-drill.sh --build   # 14 more, and a real dump and restore
```

`verify.sh` is the whole thing: it creates the three application roles once, then builds a
separate database per suite, applies the model, runs the suite and drops the database. It
exits non-zero if a single check failed.

A suite needs a database of its own because each one seeds its own fixtures and then tries
to violate them — running two against the same database fails on the first one's seed data
rather than on anything real. That is why the script exists rather than a list of commands
to paste.

By hand, one suite at a time, the same way the script does it:

```bash
psql -d postgres -f roles.sql          # once per cluster

createdb dc_check
for f in schema.sql authentication.sql access-policies.sql data-classification.sql \
         agreements.sql incidents.sql identity-policies.sql access-matrix.sql \
         audit-logging.sql retention.sql environments.sql vendors.sql \
         backup-recovery.sql phi-safe-logging.sql encryption-and-secrets.sql \
         boundary.sql grants.sql \
         checks-support.sql; do
  psql -v ON_ERROR_STOP=1 -d dc_check -f $f
done
psql -d dc_check -f schema-invariants.sql     # 24 checks
dropdb dc_check                               # and again for the next suite
```

The suites are: `schema` (24), `access` (38), `audit` (13), `retention` (38),
`environment` (37), `vendor` (23), `backup` (34), `logging` (27), `auth` (26),
`secrets` (21), `boundary` (37). Access is 39.

Each prints `PASS` or `FAIL` per check, on stderr. A `FAIL` means a guarantee has been
removed — which is sometimes the right thing to do, but it should be a decision rather than
a discovery.

### Who you are running as matters

The checks pass as a superuser and as a non-superuser with `CREATEDB` and `CREATEROLE`,
and both are tested. The difference is not cosmetic: a superuser bypasses row-level
security entirely, so a suite run as one can report success while the policies under test
were never consulted. A managed instance gives nobody a superuser, which is what production
will actually be.

`checks-support.sql` is what makes the two agree. It lets each suite lift `FORCE` on the
PHI tables for its own owner-level reads and put it back at the end, so a check that counts
what survived a deletion is counting rows rather than counting what a policy let it see.
Every check that tests a policy does it by becoming `dailycare_app` or
`dailycare_retention` and asking as them.

If you cannot create roles, ask for these four once and then run everything else as
yourself:

```sql
CREATE ROLE dailycare_app NOLOGIN;
CREATE ROLE dailycare_retention NOLOGIN;
CREATE ROLE dailycare_integration NOLOGIN;
CREATE ROLE dailycare_backup NOLOGIN BYPASSRLS;   -- BYPASSRLS needs a superuser
GRANT dailycare_app, dailycare_retention, dailycare_integration, dailycare_backup
  TO <your user>;
```

`dailycare_backup` is the only role that bypasses row-level security, and it exists for one
reason: `pg_dump` run by the owner fails on every PHI table while `FORCE` is on. That is the
correct failure — `pg_dump --enable-row-security` succeeds instead and silently dumps only
the rows the policies admitted, which is a partial backup that looks complete.

The classification has one further check, and it is a query rather than a script:

```sql
SELECT * FROM unclassified_columns;   -- must be empty
SELECT * FROM unscrubbed_columns;     -- must be empty
SELECT * FROM phi_inventory;          -- what goes to the reviewer

SELECT * FROM access_matrix_report;            -- the role and access-control matrix
SELECT * FROM access_matrix_blanks;            -- must be empty
SELECT * FROM access_matrix_delete_drift;      -- must be empty
SELECT * FROM access_matrix_uncovered_tables;  -- must be empty

SELECT * FROM never_log;              -- field names a log line may not contain
SELECT * FROM notification_audit;     -- every template, and what it may interpolate
SELECT * FROM monitoring_signals;     -- what is watched and who hears about it

SELECT * FROM secrets_inventory;      -- every secret, where it lives, who may read it
SELECT * FROM secrets_never_rotated;  -- and the argument for each one
SELECT * FROM encryption_controls;    -- including what was declined, and why
SELECT * FROM phi_stores_without_encryption;  -- must be empty
SELECT * FROM session_inventory;      -- sessions per person, active and revoked

SELECT * FROM boundary_channels;      -- which way anything may cross, and what is open
SELECT * FROM boundary_blocked_channels;  -- shut, and what opening each would require
SELECT * FROM boundary_leaks;             -- must be empty
SELECT * FROM boundary_reminiscence_leak; -- must be empty
SELECT * FROM boundary_database_joins;    -- must be empty

SELECT * FROM app_privileges;         -- what the application is granted, declared
SELECT * FROM grant_drift;            -- must be empty, in both directions
SELECT * FROM app_can_delete;         -- must be empty
SELECT * FROM app_owns_something;     -- must be empty
SELECT * FROM app_reaches_the_register;   -- must be empty

SELECT * FROM residents_without_agreement;  -- must be empty
SELECT * FROM agreements_expiring_with_residents;  -- the one nothing else notices
SELECT * FROM notifications_overdue;        -- must be empty
SELECT * FROM notifications_late;           -- kept on record, not refused
SELECT * FROM incidents_unassessed;         -- must be empty

SELECT * FROM deidentification_undetermined;  -- expected to have a row, and says why

SELECT * FROM phi_vendors;            -- who else touches a resident record
SELECT * FROM vendor_gaps;            -- what is not agreed yet, and who owns closing it
SELECT * FROM live_without_agreement; -- must be empty
SELECT * FROM unacknowledged_gaps;    -- must be empty
SELECT * FROM uncontrolled_exposure;  -- must be empty

SELECT * FROM backup_policies;        -- what is kept, how long, and who may restore it
SELECT * FROM policies_not_in_effect; -- which of those are still plans
SELECT * FROM never_drilled;          -- environments nobody has restored from yet
SELECT * FROM in_effect_without_drill;-- must be empty
SELECT * FROM rto_missed;             -- must be empty
```

A column added in a later migration arrives unclassified and appears in the first query.
That is deliberate: the inventory is generated from the database rather than maintained
beside it, so it cannot quietly stop being true.

## Against the InkTree field guide

`inktree-alignment.md` is the divergence review. The short version: the framework, the
database engine, the platform and the relation-as-a-row model already agree; the backend
language, the service count and the event bus are open questions whose answers do not touch
anything in this directory, because all of it is PostgreSQL rather than application code.

The one that is not a preference is the direction data flows. InkTree into DailyCare is
safe. DailyCare into InkTree puts every service that can reach the record into HIPAA scope,
along with the model and voice providers behind it — which is a decision worth making
deliberately rather than discovering after the first feature that needed it.

## The review package, item by item

What Milestone 2 asked for, and where each of it is. Nothing here is a document describing
a control; where a row says "generated" the answer is produced from the database, and where
it says "checked" a failing suite is what drift looks like.

| Asked for | Where | |
|---|---|---|
| Architecture and data-flow diagram | `architecture-diagram.md` | four diagrams, rendered |
| PHI inventory: created, transmitted, processed, stored | `data-classification.sql`, diagram 2 | generated |
| GCP services used, and which handle PHI | `vendors.sql` | checked |
| Authentication and authorisation model | `authentication.sql`, `access-policies.sql` | checked |
| Role and access-control matrix | `access-matrix.sql` | checked against the catalogue |
| Resident, caregiver, family, facility relationships | `schema.sql` | checked |
| Audit logging design | `audit-logging.sql` | checked, with a canary |
| Retention and deletion design | `retention.sql` | checked |
| Encryption and secrets management | `encryption-and-secrets.sql` | checked |
| PHI-safe logging, monitoring, notification | `phi-safe-logging.sql` | generated and checked |
| Development, test and production separation | `environments.sql` | checked |
| Backup and recovery | `backup-recovery.sql`, `restore-drill.sh` | drilled |
| Third-party and vendor inventory | `vendors.sql` | checked |
| Assumptions, open questions, reviewer confirmations | this file, below | — |

The other half of Milestone 2 — the backend running on GCP, accounts in use, data moving
between real devices — is not here and is not claimed. It waits on the project, the billing
account and IAM. What is here is the model those will be built on, and it is the part that
can be reviewed before rather than after.

## What the model assumes

**Every row belongs to a facility.** Multi-tenancy is in the first migration because
adding a tenant column to a populated table is a different kind of job.

**Identity is a generated UUID, never a name.** A resident keeps their identity through a
name correction, a transfer, or a readmission — and a UUID is safe in a log line in a way
a name is not.

**A relationship is a row with a type, never a boolean on a person.** InkTree reached the
same conclusion the expensive way, with `relation = 'self'` rather than `is_user`. Using
the same shape means the two models can be reconciled later rather than translated.

**Medication is an event with a source.** A caregiver's entry and a MedTech's record in a
clinical system occupy the same table, carry two timestamps — when the dose happened and
when the system was told — and say which they are. Nothing written through a request may
claim to have come from a clinical system.

**A care day is amended by adding.** Corrections insert a new row and stamp the old one
superseded. There is no path that rewrites what a day said, and the application has no
`DELETE` policy on any table, for any role.

**A write is audited by the database, not by the handler.** Every insert or update of a
PHI table fires a trigger, so there is no code path that changes a care record without
producing a row. The application cannot write an audit row by hand either — insert,
update and delete on `audit_events` are revoked from it, so a compromised session cannot
append a plausible history or remove an inconvenient one. What is recorded is which
columns changed, never what they changed to.

**Destruction is stated twice.** Deletion is the one operation nobody can undo, so it is
the last place to rely on a function being written correctly. What may be destroyed is
written once as the job and once, independently, as row-level security: if the job asked
to delete a resident who is still in the building, the database would remove nothing.
Retention runs as its own role, which can see which rows are due and delete them but
cannot read a care note, a resident's name or a medication status — and the application
cannot invoke it.

**A photograph is deleted by handshake.** A photo is a row here and an object in a bucket.
The database says what is due, the job empties the bucket, and only then may the row go —
enforced, not agreed: the policy refuses to delete a media row whose object has not been
confirmed gone. A resident whose photographs are still in storage keeps their whole record
until the next run.

**Development and test hold no PHI, and that is a mechanism rather than a promise.** The
sentence survives the first week; then a bug only reproduces on real data, somebody
restores last night's backup into staging to look at it, and no document notices. So a
snapshot is scrubbed in place before an application is pointed at it, and the scrub rules
are a table with a completeness check — a column added in a later migration arrives
without a rule and the scrub refuses to run at all. What is kept is kept deliberately, with
a reason recorded: once names are gone and every date has moved by one offset, a mood and a
meal amount are what make the copy worth developing against.

**A restored copy knows it is a copy.** The dangerous moment in a backup strategy is not
the backup. It is the twenty minutes after a restore, when a production snapshot is sitting
in a database called something like `dailycare_dev` with a laptop already pointed at it.
The deployment row records the database and the instance it was written in, and travels
inside the dump — so when it lands anywhere else it no longer matches, and `app_user_id()`
returns null until a scrub has run under this database's own name. Every policy in the
access model inherits that at once, because they all resolve from the same function. A
production recovery is not blocked: it takes one deliberate statement that says this is the
database now, and records who decided that.

**A credential column refuses anything but a digest.** "Passwords are hashed" is otherwise
a property of whichever handler last wrote the row, and stops being true the day a second
one appears — an import, a seeding script, a migration written in a hurry. A check
constraint is the enforcement; a trigger using the same predicate runs first and produces
the refusal, because PostgreSQL reports a failing row in full and the rejection of a
plaintext password would otherwise be a message containing that password, on its way to
wherever errors are logged. The suite proves both halves: the refusal repeats nothing, and
with the trigger switched off it would have.

**Content crosses inward; nothing crosses outward, and that is a structure rather than a
sentence.** Every path between the two systems is a row, every field on every path is
checked against the classification, and no outbound channel may so much as name a table
that holds a resident's record. The one outbound channel anybody has thought of is written
down and shut, with what opening it would cost: even a pseudonym plus a timestamp is a code
derived from a patient identifier, which Safe Harbor excludes, so opening it is an
agreement rather than a configuration change.

The likelier accident is not a payload. The InkTree platform is one PostgreSQL instance
that every one of its services reads and writes directly, so joining the two databases —
a foreign data wrapper, a dblink, or simply a DailyCare schema in that instance — puts nine
services and their vendors into scope with nothing published to say so. It is the cheapest
thing to propose, and `boundary_database_joins` must be empty.

**A development copy shares no key with production.** The names in a scrubbed copy were
synthetic and the dates had moved, and the resident's uuid was the same one the production
log line carried — so the mood, appetite, meals and medication status deliberately kept for
developers were one join away from a request, a user and a facility. "Carries no meaning"
is true of a uuid by itself; a uuid stable across two copies of a record is a code assigned
to the individual, which is what this package already refuses to send to InkTree for
exactly that reason. The copy now re-keys residents, care days and the audit columns from a
salt discarded when the run ends, and every foreign key follows.

**And the copy does not claim to be de-identified.** Dates are shifted rather than removed,
which keeps the intervals a developer needs and keeps the data a limited data set rather
than de-identified under Safe Harbor. The route that fits is an expert determination, which
is a signature and not a constraint — so what is here is its absence, named, the way
`never_drilled` and `vendor_gaps` are named.

**A resident is admitted into a facility that has an agreement, or not at all.** The
package modelled every agreement flowing down — the platform, the messaging vendor, the
clinical system — and nothing about the one flowing up. A facility could be created and a
resident admitted with no business associate agreement, and the vendor register would have
reported every downstream agreement signed and been right. Admission is now a policy that
consults the agreement, and the case nothing else would notice — a contract ending while
residents are still inside — is a view.

**An incident has somewhere to go, and the clock is the agreement's.** The four factors
must all be filled before a conclusion may be recorded, because a conclusion of "not a
breach" reached without the assessment is the answer the rule presumes against. The
deadline is the window the agreement sets or the rule's sixty days, whichever is shorter;
`notifications_overdue` must be empty and `notifications_late` deliberately need not be —
a notification sent late is still a notification and the record of it has to survive.

**The audit window has a floor.** Six years, because the trail is the accounting of
disclosures a facility owes a resident and the record of security activity a business
associate must retain, and a facility that chose thirty days would have had both destroyed
on schedule by a job working exactly as designed. The care-record number stays the
facility's to choose and now has to name what it rests on.

**Row-level security is on the tables that say who people are, too.** Nine PHI tables
forced it and twenty-five others did not, and those twenty-five included `users`,
`facility_members`, `assignments`, `sessions` and the audit trail. The application has to
read `users` to sign anybody in, and the moment it could it could read every staff and
family address at every customer. The completeness view had not noticed because it asked
only about tables with a PHI column, and these are classified identifying — a caregiver's
email is not PHI; a list of every family member granted access to a resident in memory
care, across every customer, is what breach notification is written about. `ENABLE` rather
than `FORCE` here, because a forced policy that consults a helper reading its own table
recurses, and what `FORCE` was standing in for is now asked directly by
`app_owns_something`.

**What the application is granted is a table, not a migration.** No file in the model
granted `dailycare_app` anything; the only grants were in the check suites, and they were
`ON ALL TABLES`. So the suites were not testing the privilege surface, and the first
deployment would have decided it. The baseline is declared, applied from the declaration,
and compared to the catalogue in both directions — a privilege granted by hand and one
written down but never applied are both findings. `UPDATE` on `care_days` is
`superseded_at` and nothing else, which is the second half of amend-by-adding: the trigger
refuses a rewrite, and this means the request never reaches the trigger.

**A definer function pins its own search_path.** A `SECURITY DEFINER` function runs with
the privileges of whoever wrote it, and every one of these exists to answer a question
about who may see a resident — so an unqualified call inside one lets a caller who controls
`search_path` put their own function in front of the real one and have it run as the
definer. All eleven pin it, and so does every function reached from a constraint or a
trigger. It was found the ordinary way rather than by reading about it: `pg_dump` restores
with an empty `search_path`, and the database could not be restored from its own dump.

**A credential is not stored, and a session is one function rather than a condition
repeated at every call site.** Authentication is the API's job, which makes it the weaker
half by construction, so what could be moved into the database has been: a refresh rotates
in the same statement that revokes the one it replaces, so a stolen token dies the moment
the real client uses theirs; a single-use token is consumed atomically, so an invitation
forwarded to a whole family admits one person whatever order the requests arrive in; and
signing out of one device leaves the others signed in, which is a row a reviewer can be
shown rather than a sentence.

**A secret in the repository is a refused row, not a review finding.** The two places a
credential must never be are the two places it always ends up. Both are unrepresentable in
the register. What is kept instead of a password is a digest the column refuses to hold in
any other form. Two controls were declined — customer-managed keys and field-level
encryption — and the reasons are recorded, because the threat customer-managed keys creates
is losing the key, after which nobody reads the records, including the facility whose they
are.

**A log line may not carry a field name from the classification.** The realistic way a
resident's name reaches Cloud Logging is a developer serialising a row at two in the
morning, and a serialised row carries its column names with it. So `never_log` is generated
from the classification and `log_scan()` checks a candidate line against it — a guard that
says "this line should not have been written", not a filter that quietly removes the name.
Several forbidden fields collide with ordinary logging vocabulary; that is a naming rule
rather than a false positive, and an HTTP status is logged as `http_status`.

**A notification says that something happened, never what.** There is no placeholder for a
resident's name and none for anything clinical, so the warm version somebody will ask for —
"Cathy had a difficult night" — is a refused row rather than a review conversation. It ends
up on a lock screen in a room with other people in it.

**The access matrix is a table, and it is checked against the database it describes.** A
matrix in a document says what the application intends; the policies say what the database
permits, and nothing compares them. Here the matrix is 192 cells with no blanks allowed,
and two views cross-check it against the catalogue. It earned that on its first run: it
found `FOR ALL` write policies on four tables, and `ALL` includes `DELETE` — so a care
manager could delete a resident and a family grant, and a caregiver a meal, while this
README said no such path existed. The check that should have caught it was passing for the
wrong reason: it attempted the delete without identifying anybody, so the row was hidden
rather than protected.

**A third party that could receive PHI by accident needs a control, not a contract.** The
vendors everyone remembers are the ones the data is sent to. The one that gets missed is
the logging service that receives whatever an error message happened to contain, and no
agreement stops a stack trace carrying a resident's name. So exposure is recorded as four
kinds and anything marked `could_receive` must name what stops it — enforced by a
constraint, not by a view noticing afterwards. The register is also allowed to hold an
uncomfortable answer: gaps are expected, and what must be empty is the set of gaps with
nobody's name on them and the set of vendors already carrying live records without an
agreement.

**An unidentified request sees nothing.** Access resolves from a session variable the
application sets per request. Unset compares false everywhere, so the failure mode of
forgetting to set it is an empty result rather than an open door.

## Open questions for the reviewer

These are judgements rather than facts, and worth confirming rather than assuming.

- A caregiver reaches only the residents currently assigned to them, not the whole
  building. That is the stricter reading of least privilege; a facility that rotates
  staff hourly may find it operationally wrong.
- `resident_contacts.relation` is classified as PHI on the grounds that "child of a
  resident in care" is attached to a patient. That may be stricter than required.
- Audit rows are written for reads as well as writes. The volume implication at facility
  scale has not been measured yet.
- Retention windows are per facility and the table carries no defaults, so a facility
  that has not decided has retention refused rather than guessed. Someone has to decide
  what Cedar House's numbers are.
- The storage half of media deletion is the one piece outside the database: a worker that
  reads `retention_due_media`, removes each object, and calls `retention_confirm_media`.
  The contract is fixed and tested; the worker follows the backend language decision.
- The scrub replaces a care note with filler of the same length, so a layout bug still
  reproduces in dev. Length is the one thing it leaks. That reads as a reasonable trade
  here and is worth a second opinion.
- The restore gate stops the application, not a person with direct database access. It
  buys the window between a restore and a scrub, which is where the accident happens; it is
  not a substitute for who holds the recovery role.
- `imported_content.body` is classified as PHI on the grounds that a family story filed
  against a named resident in memory care is attached to a patient. The content is not
  health information; what it is attached to is. That may be stricter than required.
- Project-level separation — one GCP project per environment, no shared service account,
  no path from a dev workload to a production bucket — is infrastructure rather than
  schema, and waits on the project and billing setup.
- Reads are the weak half of the audit design and deliberately flagged as such.
  PostgreSQL cannot trigger on `SELECT`, so a read is recorded by the application calling
  `audit_read()` on the single path that serves resident data. That is a convention the
  code has to keep rather than a guarantee the database enforces, and it is the one place
  where a forgetful handler still produces a gap.
