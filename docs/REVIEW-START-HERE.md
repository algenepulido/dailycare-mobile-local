# DailyCare — start here

For a reviewer assessing whether this system is fit to hold protected health
information. It assumes no familiarity with the codebase and asks you to install
nothing. Everything below can be read; if you want to verify any of it yourself,
each section says where the evidence is and how to reach it.

Fifteen minutes end to end. The links are for afterwards.

---

## What the system is

DailyCare is a caregiver application for residential care. A caregiver records
a resident's day — meals, hygiene, mood, a note, sometimes a photograph — on a
phone. A care manager sees every resident in their building. A family member,
in a later milestone, will see their own person and nobody else.

There are three pieces: the phone application, an API, and a PostgreSQL database
on Google Cloud. Residents' records exist in exactly one place, the database.
The phone holds an in-progress day until it is sent, and photographs live in
private cloud storage that is reachable only through a link the API mints after
checking who is asking.

## Where the health information is

The database has 49 tables and 384 columns. Every column is classified, and the
classification is a table in the database rather than a document beside it:

- **37 columns are PHI**, spread across 11 tables
- **16 columns identify a person** without being clinical
- **4 hold secrets** — password hashes and token digests, never the values
- the remaining 327 are operational: timestamps, foreign keys, configuration

A column added without a classification fails the build. That is the mechanism
that keeps the list above true rather than accurate on the day it was written.

Medication is the deliberate exception. A caregiver ticks that they gave a
medication on the phone, and that tick is not sent. Recording that a drug was
dispensed is a different claim from recording that a caregiver believes they
gave it, and the system does not blur them.

## Who can see what

Access is decided by the database, not by the application. Every request runs
under the identity of the person making it, and the database applies row-level
security to every table holding resident data — including when the connection
belongs to the owner of the schema, which is the case most systems leave open.

- a **caregiver** reads and writes the residents they are assigned to
- a **care manager** reads and writes every resident in their own facility
- a **family member** reads their own resident, and cannot write
- the **application's own role** can create nothing and owns nothing

The complete matrix is 120 table-and-operation rows, held as data and checked
against the live database in both directions: nothing in the matrix that the
database does not enforce, and nothing the database enforces that the matrix
does not mention.

The practical consequence, and the one worth testing yourself in the walkthrough:
a care manager with no assignments at all sees every resident in their building,
and a caregiver with no assignments sees none. Same building, same data, and the
only difference is the role.

→ [`access-matrix.sql`](architecture/access-matrix.sql) ·
  [`access-policies.sql`](architecture/access-policies.sql)

## The audit trail

Ten tables carry an audit trigger; there are no gaps, and a PHI-bearing table
without one fails the build. Reads are recorded as well as writes, which
PostgreSQL cannot do by itself — the application records them, on the single
path that serves resident data, in the same transaction as the read. A read that
is not in the trail is a read that did not happen.

Two properties the trail is built around:

**The application cannot write its own history.** It holds no privilege to insert
into the audit table. Rows arrive only through the functions the database runs
on its own authority.

**The trail does not quote the record it protects.** A care note containing a
string that exists nowhere else is written, and every column of every audit row
is searched for it. An audit trail that copies the record has become a second
copy of that record, usually with a longer retention and weaker access.

Who may read it: a care manager, for their own facility. Not a caregiver, not a
family member — though a facility owes a family an accounting of disclosures and
would produce it from here.

→ [`audit-logging.sql`](architecture/audit-logging.sql)

## Backup and restore

Backups are Cloud SQL's managed snapshots. What matters more is that a restore
is rehearsed rather than assumed: the check suite takes a real dump, restores it
under another name, and proves three things about the copy — that it knows it is
not where it was written, that it refuses to serve until it has been scrubbed of
real data, and that nothing of the original survives the scrub.

That rehearsal found a real defect: the database could not be restored from its
own dump, because a restore runs with an empty search path and an unqualified
call inside a function fails. Eleven functions were affected, all of them
answering questions about who may see a resident. The same gap is the standard
route to turning such a function against its own database.

Retention is per facility and set by the facility, not by us: how long a care
record is kept, how long a photograph is kept, how long the audit trail is kept.
The job that applies it runs as its own role and is the only thing that may
delete a care record.

→ [`backup-recovery.sql`](architecture/backup-recovery.sql) ·
  [`retention.sql`](architecture/retention.sql)

## Vendors and BAAs

Seven vendors are recorded, each with its role, whether it is live, and the state
of its agreement:

| | |
|---|---|
| Google Cloud Platform | processor, live, **BAA signed 10 September 2026** |
| Google Cloud Logging | subprocessor, live, **covered by the same BAA** |
| Expo Application Services | processor, live, build service — no PHI, BAA not required |
| Apple App Store / Google Play | conduit, live, BAA not required |
| Twilio | conduit, **not live**, BAA offered and not signed |
| Stripe | processor, **not live**, no PHI in scope |
| PointClickCare | data source, **not live**, no BAA offered |

Nothing that is not live can be reached: a vendor without a signed agreement
where one is required cannot be configured on.

One channel is deliberately closed. InkTree's other products would like a signal
that something happened for a pseudonymous subject — no name, nothing clinical.
It is closed anyway, because a stable code plus timestamps is a pseudonymous
record of a person, and Safe Harbor excludes codes derived from patient
identifiers. Opening it needs an agreement and a recorded decision, not a
configuration change.

→ [`vendors.sql`](architecture/vendors.sql) · [`boundary.sql`](architecture/boundary.sql)

## What the 541 checks prove

The package is executable. It builds a throwaway PostgreSQL database from the
model, runs 541 checks across fourteen suites plus the restore rehearsal, and
removes the database afterwards. Any single failure fails the run.

The checks are written as attempts rather than assertions: they become a
caregiver and try to read a resident in another building, try to file a day for
somebody they are not assigned to, try to edit the audit trail, try to create a
table in the schema the application reads. What they prove is that those attempts
are refused, by the database, under the identity of the person making them.

They run as an ordinary database user on purpose. A superuser bypasses row-level
security entirely, so the same suite run as one would report success while the
policies under test were never consulted — and a managed instance, which is what
production is, gives nobody a superuser.

**What they do not prove.** The suite proves the model is coherent. It does not
prove that the deployed environments are running that model. Those are different
claims and only one of them is in the repository. The environments are checked by
a separate job that runs the same suites against the real instance; we would
rather you ran it yourself than took our word for it, and access can be arranged.

## What is still open

Thirteen administrative requirements are recorded as not yet met, each with an
owner and the point it has to be met by. They are InkTree's to complete rather
than the software's, and they are listed here rather than left to be discovered.

**Overdue now**

- a named security official — one person responsible for the policies
  (§164.308(a)(2))
- an evaluation cadence — how often the checks and the vendor register are run,
  and by whom. The technical evaluation exists and runs in one command; what is
  missing is somebody whose job it is to run it (§164.308(a)(8))

**Before the first real record**

- a risk analysis and a risk management plan (§164.308(a)(1)(ii)(A), (B))
- a sanction policy (§164.308(a)(1)(ii)(C))
- workforce authorisation and clearance procedures (§164.308(a)(3))
- security awareness training (§164.308(a)(5))
- an incident response procedure (§164.308(a)(6))
- an emergency mode operation plan (§164.308(a)(7)(ii)(C))
- media disposal (§164.310(d)(2))

**At other points**

- a lost-device procedure, with each facility, before the client ships against
  real data (§164.310(d)(1))
- a workstation policy — where a scrubbed copy may live and what a developer
  laptop must have on it — before the first restore (§164.310(b), (c))
- an applications and data criticality analysis, before the GCP project
  (§164.308(a)(7)(ii)(E))

They are held the same way as everything else: as rows, with a view that fails
the build if one loses its owner or its date.

→ [`emergency-and-program.sql`](architecture/emergency-and-program.sql)

## Going deeper

Everything above is generated from the same files the checks run against, so it
cannot describe a system other than the one that was tested.

- [`architecture/README.md`](architecture/README.md) — every file, and what it is for
- [`architecture/architecture-diagram.md`](architecture/architecture-diagram.md) —
  four diagrams: the pieces, where a resident's record exists, one request end to
  end, and the single flow that leaves the database
- [`gcp-as-built.md`](gcp-as-built.md) — the cloud project as it actually stands

To run the checks yourself you need Docker and nothing else:

    cd docs/architecture
    ./review.sh

It takes a few minutes and prints a line per suite.
