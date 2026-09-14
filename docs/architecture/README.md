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

## Verifying it

Everything below runs against a scratch database and leaves nothing behind. PostgreSQL 14
or newer.

```bash
createdb dc_check

psql -v ON_ERROR_STOP=1 -d dc_check -f schema.sql
psql -v ON_ERROR_STOP=1 -d dc_check -f access-policies.sql
psql -v ON_ERROR_STOP=1 -d dc_check -f data-classification.sql

psql -d dc_check -f schema-invariants.sql     # 14 checks
psql -d dc_check -f access-invariants.sql     # 24 checks

dropdb dc_check
```

Both invariant files print `PASS` or `FAIL` per check, on stderr. A `FAIL` means a
guarantee has been removed — which is sometimes the right thing to do, but it should be a
decision rather than a discovery.

They are not idempotent, and deliberately so: each seeds its own fixtures and then tries
to violate them. Running one twice against the same database fails on its own seed data
rather than on anything real. Drop and recreate between runs.

The classification has one further check, and it is a query rather than a script:

```sql
SELECT * FROM unclassified_columns;   -- must be empty
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
superseded. There is no path that rewrites what a day said, and no `DELETE` policy
anywhere in the access model.

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
- Retention is per facility and enforced by a scheduled job running as its own role. The
  job is not built yet; the policy table it will read is.
