# Architecture and data flow

Four diagrams. The first says what the pieces are; the second says where a resident's
record exists and where it does not, which is the one a reviewer is actually asking for;
the third follows a single request so that the identity check and the audit row have a
place rather than a paragraph; the fourth is the only flow that leaves the database.

Everything below is the target architecture. Nothing is deployed yet — the platform
agreement is signed, the project is not created. What exists today is the model in this
directory and the mobile client from Milestone 1.

---

## 1. The pieces

```mermaid
graph TB
  subgraph devices["Devices"]
    CG["Caregiver<br/>iOS and Android"]
    FM["Family member<br/>iOS and Android"]
    MG["Care manager<br/>same app, more of it"]
  end

  subgraph gcp["Google Cloud — covered by the platform agreement, signed 10 Sep 2026"]
    API["API<br/>Cloud Run"]
    DB[("PostgreSQL<br/>Cloud SQL")]
    GCS[("Photographs<br/>Cloud Storage")]
    SM["Credentials<br/>Secret Manager"]
    LOG["Logs<br/>Cloud Logging"]
    JOB["Retention job<br/>Cloud Run job, own identity"]
  end

  subgraph outside["Outside the platform"]
    PCC["PointClickCare<br/>the facility's clinical system"]
    SMS["Twilio<br/>invitations and sign-in codes"]
  end

  CG --> API
  FM --> API
  MG --> API
  API --> DB
  API --> GCS
  API --> SM
  API --> LOG
  JOB --> DB
  JOB --> GCS
  PCC -->|"medication records"| API
  API -->|"a link and a code, no name"| SMS
  SMS -->|"text message"| FM

  classDef phi fill:#7f1d1d,stroke:#450a0a,color:#fff
  classDef near fill:#78350f,stroke:#451a03,color:#fff
  class DB,GCS phi
  class API,JOB,PCC near
```

---

## 2. Where the record is

The colour is the whole diagram. Red holds a resident's record. Amber handles it without
keeping it. Everything unshaded never sees one, and the arrows into it are what keep that
true.

```mermaid
graph LR
  subgraph created["Created"]
    C1["A caregiver files a day<br/><i>mood, appetite, sleep, a note</i>"]
    C2["A photograph is taken"]
    C3["A MedTech records a dose<br/><i>in the clinical system</i>"]
  end

  subgraph transmitted["Transmitted"]
    T1["TLS 1.2+<br/>device to API"]
    T2["TLS<br/>API to database"]
    T3["Signed URL<br/>minted per request, short-lived"]
  end

  subgraph processed["Processed"]
    P1["API handlers<br/><i>in memory only</i>"]
    P2["Retention job<br/><i>identifiers, never a note</i>"]
  end

  subgraph stored["Stored"]
    S1[("care_days, residents,<br/>medication_events,<br/>resident_contacts")]
    S2[("Photograph objects")]
    S3[("audit_events<br/><i>who touched what, never what it said</i>")]
  end

  subgraph never["Never holds a record"]
    N1["Cloud Logging<br/><i>uuids and codes</i>"]
    N2["Twilio<br/><i>a link and a code</i>"]
    N3["Expo build service<br/><i>no database connection</i>"]
    N4["Stripe<br/><i>a facility is a business</i>"]
  end

  C1 --> T1 --> P1 --> S1
  C2 --> T1
  C2 --> T3 --> S2
  C3 --> P1
  P1 --> T2 --> S1
  P1 -.->|"column names only"| S3
  P1 -.->|"identifiers only"| N1
  P1 -.->|"no name, nothing clinical"| N2
  S1 --> P2
  S2 --> P2

  classDef phi fill:#7f1d1d,stroke:#450a0a,color:#fff
  classDef near fill:#78350f,stroke:#451a03,color:#fff
  classDef clean fill:#14532d,stroke:#052e16,color:#fff
  class C1,C2,C3,S1,S2 phi
  class T1,T2,T3,P1,P2,S3 near
  class N1,N2,N3,N4 clean
```

`audit_events` is amber rather than red on purpose. It records which columns changed and
never what they changed to, and that is proven rather than asserted: a care note is written
containing a string that exists nowhere else, and every column of every audit row is then
searched for it.

---

## 3. One request

Where identity is established, where the policies apply, and where the audit row comes
from. The last is the point: it is a consequence of the write rather than something a
handler remembers to do.

```mermaid
sequenceDiagram
  autonumber
  participant App as Caregiver app
  participant API as API (Cloud Run)
  participant DB as PostgreSQL
  participant Log as Cloud Logging

  App->>API: POST /care-days<br/>Authorization: Bearer <access token>
  API->>API: verify token signature and expiry
  Note over API: fails here → 401, nothing reaches the database
  API->>DB: SET LOCAL app.user_id, app.role, app.request_id
  Note over DB: unset would mean null,<br/>and null compares false in every policy
  API->>DB: INSERT INTO care_days ...
  DB->>DB: policy: is this caregiver assigned to this resident?
  alt not assigned
    DB-->>API: row-level security violation
    API-->>App: 403
    API->>Log: request_id, user uuid, code — no name, nothing clinical
  else assigned
    DB->>DB: trigger writes audit_events<br/>actor, action, resident uuid, column names
    DB-->>API: the new row
    API-->>App: 201
    API->>Log: request_id, user uuid, 201
  end
```

Reads are the honest gap and are marked as such wherever they appear. PostgreSQL cannot
trigger on `SELECT`, so a read is recorded by the application calling `audit_read()` on the
single path that serves resident data. That is a convention the code keeps rather than a
guarantee the database enforces, and it is the one place a forgetful handler still produces
a gap.

---

## 4. The one flow that leaves the database

A photograph lives in two places, so deleting it is a handshake rather than a statement.
The database will not let the row go until storage has confirmed the object is gone, and a
resident whose photographs are still in the bucket keeps their whole record until the next
run.

```mermaid
sequenceDiagram
  autonumber
  participant Job as Retention job
  participant DB as PostgreSQL
  participant GCS as Cloud Storage

  Job->>DB: retention_due_media(facility)
  DB-->>Job: bucket and path for each object due
  loop each object
    Job->>GCS: delete object
    GCS-->>Job: gone
  end
  Job->>DB: retention_confirm_media(ids)
  Note over DB: stamps deleted_at.<br/>One way: the update policy accepts<br/>null becoming a timestamp and nothing else
  Job->>DB: apply_retention(facility)
  Note over DB: the delete policy refuses any media row<br/>whose object is not confirmed gone,<br/>so a job that deleted rows first removes nothing
  DB-->>Job: counts per table
  DB->>DB: audit_events: retention.applied, counts, no names
```

---

## What the diagrams assume

**Every arrow into the platform is TLS.** Device to Cloud Run, Cloud Run to Cloud SQL,
Cloud Run to Cloud Storage. The database is reached over a private address and is not
published to the internet.

**A photograph is never served from a public URL.** The row in `media_objects` is what
gates a signed link, and the link is minted after the policy has admitted the caller, never
before — so possession of a URL is not permission, and a withdrawn grant cannot be replayed
by keeping an old one.

**The retention job is not the API.** Separate identity, separate database role, and the
application cannot invoke it. A compromised session cannot cause a deletion.

**Medication flows one way.** Records arrive from the clinical system through the
integration role and carry a reference back to the record they came from. Nothing written
through a request may claim to have come from a clinical system.

**Nothing crosses into InkTree.** Not in this architecture. The reasoning, and what it
would cost to change, is in `inktree-alignment.md`.
