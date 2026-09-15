# Architecture

The data model, the access model, and the classification the review package is generated
from. Milestone 2 work, kept as SQL rather than as prose because a description of a
constraint and a constraint are different things, and only one of them stops a mistake.

## The files

| | |
|---|---|
| `schema.sql` | The production schema. 15 tables, 12 enums. Applied first. |
| `schema-invariants.sql` | The guarantees the schema makes, written as the smallest statements that prove them. Self-reporting. |
| `access-policies.sql` | The three roles as row-level security. Applied after the schema. |
| `access-invariants.sql` | Attempts to reach things that should be unreachable. Runs as a non-superuser, because a superuser bypasses row-level security and would report that everything works. |
| `data-classification.sql` | Which columns hold PHI, and the views that generate the inventory from it. |
| `audit-logging.sql` | Triggers that record every write to a PHI table, and the coverage views that find a table without one. |
| `audit-invariants.sql` | Including the canary: a care note written with a unique string, then every column of every audit row searched for it. |
| `retention.sql` | When a record is destroyed, who is allowed to destroy it, and the handshake with object storage. |
| `retention-invariants.sql` | Counts rows in the tables themselves after a retention run, because a soft delete would pass a test that only asked the API. |
| `environments.sql` | How a production snapshot becomes a database a developer may hold: what is replaced, what is deliberately kept, and the two locks that stop it running anywhere near production. |
| `environment-invariants.sql` | Plants a unique string in every sensitive field, scrubs, then searches every column of every table for all of them. |

## Verifying it

Everything below runs against a scratch database and leaves nothing behind. PostgreSQL 14
or newer.

```bash
createdb dc_check

psql -v ON_ERROR_STOP=1 -d dc_check -f schema.sql
psql -v ON_ERROR_STOP=1 -d dc_check -f access-policies.sql
psql -v ON_ERROR_STOP=1 -d dc_check -f data-classification.sql
psql -v ON_ERROR_STOP=1 -d dc_check -f audit-logging.sql
psql -v ON_ERROR_STOP=1 -d dc_check -f retention.sql
psql -v ON_ERROR_STOP=1 -d dc_check -f environments.sql

psql -d dc_check -f schema-invariants.sql     # 14 checks
psql -d dc_check -f access-invariants.sql     # 24 checks
psql -d dc_check -f audit-invariants.sql      # 13 checks
psql -d dc_check -f retention-invariants.sql  # 38 checks
psql -d dc_check -f environment-invariants.sql # 36 checks

dropdb dc_check
```

Each invariant file prints `PASS` or `FAIL` per check, on stderr. 125 checks in total. A `FAIL` means a
guarantee has been removed — which is sometimes the right thing to do, but it should be a
decision rather than a discovery.

They are not idempotent, and deliberately so: each seeds its own fixtures and then tries
to violate them. Running one twice against the same database fails on its own seed data
rather than on anything real. Drop and recreate between runs.

The classification has one further check, and it is a query rather than a script:

```sql
SELECT * FROM unclassified_columns;   -- must be empty
SELECT * FROM unscrubbed_columns;     -- must be empty
SELECT * FROM phi_inventory;          -- what goes to the reviewer
```

A column added in a later migration arrives unclassified and appears in the first query.
That is deliberate: the inventory is generated from the database rather than maintained
beside it, so it cannot quietly stop being true.

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
- Project-level separation — one GCP project per environment, no shared service account,
  no path from a dev workload to a production bucket — is infrastructure rather than
  schema, and waits on the project and billing setup.
- Reads are the weak half of the audit design and deliberately flagged as such.
  PostgreSQL cannot trigger on `SELECT`, so a read is recorded by the application calling
  `audit_read()` on the single path that serves resident data. That is a convention the
  code has to keep rather than a guarantee the database enforces, and it is the one place
  where a forgetful handler still produces a gap.
