# DailyCare and InkTree: where they meet and where they do not

Written against the InkTree field guide rather than against InkTree's code, so everything
here about InkTree is a reading of that document and is marked where it is an inference.
Corrections are cheap now and expensive after a service boundary exists.

The question worth answering first is not "how do we make these the same". It is "which of
these differences will cost something later, and which are two reasonable answers to
different problems". Most are the second. One is neither, and it is the last section.

---

## What already lines up, and why that was not luck

**Expo and React Native.** Same framework, same router, same build service. A developer
moves between the two products without relearning anything, and the components that are
genuinely shared — a date header, an avatar, an empty state — can be shared for real rather
than copied.

**PostgreSQL.** Same engine, same version family. Everything in this directory — row-level
security, the audit triggers, retention, the scrub — is PostgreSQL behaviour rather than
application behaviour, which is what makes it survive the decisions below.

**Cloud Run, Cloud Storage, Secret Manager.** Same platform, one agreement, one IAM model,
one place to look when something is wrong at two in the morning.

**A relationship is a row with a type.** InkTree arrived at `relation = 'self'` rather than
`is_user`, and paid for the lesson. DailyCare's `resident_contacts.relation` is the same
shape on purpose: a person's link to a resident is a row carrying a type, a grant and a
revocation, never a boolean on the person. Two models with the same shape can be reconciled
later. Two models with different shapes get translated, and a translation layer is where
the bugs live.

---

## Where they diverge

### 1. Backend language: Go and Gin, against an unstated assumption

InkTree runs nine services in Go with Gin. The DailyCare roadmap was costed without naming
a backend language, and the natural choice from the mobile side would have been
TypeScript — one language across the app and the API, one test runner, one set of types.

**What converging costs.** Less than it looks, and the reason is the point of this whole
directory. The data model, the access rules, the audit trail, the retention job and the
scrub are all in the database. They are the same whether the handler above them is Go or
TypeScript, and none of the 319 checks in this directory would change. What changes is the
handler layer: request parsing, session handling, the PointClickCare client, the media
signing path. That is real work and it is bounded.

**Recommendation.** Go, if the intention is one engineering team rather than two products
that happen to share an owner. A second language in a small team is a permanent tax paid in
context switching, and it falls hardest on whoever is on call. The one thing to check before
committing is who maintains DailyCare in a year: if the answer is "the InkTree team", the
decision is already made.

### 2. Nine services and a Redis event bus, against one service and a request

InkTree is a set of services that talk over Redis pub/sub. DailyCare at its current size is
one service with an HTTP API and no bus.

**This is not a disagreement.** It is the same system at two ages. Nine services is what a
product looks like after it has found the seams; one service is what it looks like before.
Splitting early buys nothing and costs a distributed system's failure modes for a facility
with forty residents.

**What matters is the boundary, not the count.** The thing to get right now is that
DailyCare's writes are already shaped as events — a care day was filed, a medication event
arrived, a family member was granted access — so that publishing them to Redis later is a
new subscriber rather than a rewrite. The audit trail is very nearly that event log
already, which is a convenient accident worth being deliberate about.

**Recommendation.** One service until there is a second reason for a second one. Shape the
writes as events from the start. Do not add the bus before there is something on the other
end of it.

### 3. Circle and relation, against facility and resident

InkTree's world is organised around a circle: a group of people around a person, with
relations between them. DailyCare's is organised around a facility: a regulated operator
running a building, with residents in it and staff assigned to them.

The relation half matches. The half above it does not, and it is not a naming difference.

**A circle has no operator.** Nobody is accountable for a family circle, nobody is audited,
and the people in it are there because somebody invited them. **A facility is accountable
for everything in it.** Every row in DailyCare belongs to a facility because a regulator
asks a facility, not a family, who saw a record. That is why multi-tenancy is in the first
migration rather than added later.

**What this means for a shared model.** A resident maps onto a circle subject cleanly, and
`resident_contacts` maps onto circle membership cleanly. The facility has no InkTree
analogue and should not be given one — the right reading is that DailyCare is a circle with
a regulated operator attached, and the operator is the part that does not travel.

### 4. React Native Web, against native only

InkTree ships to web through React Native Web. DailyCare's M1 is native only.

**The caregiver flow should stay native.** It is designed for a phone held in one hand in a
corridor, at the end of a shift, by somebody who wants it to take ninety seconds. Nothing
about that is better in a browser.

**The family view is a different question.** A daughter reading her mother's day on a laptop
is a reasonable thing to want, the screen is read-only, and expo-router already supports it.
This is cheap and worth doing when a facility asks for it, not before.

### 5. A voice agent per contact, against no voice at all

InkTree keys a voice agent to a `(contact, circle)` pair. DailyCare has no voice anything.

The tempting feature is obvious and somebody will ask for it: call the family in the evening
and tell them how the day went. It is also the sharpest version of the problem in the next
section, so it is dealt with there rather than here.

---

## The one that is not a preference: which way the data flows

Everything above is a design choice with a cost. This one is a boundary, and it is worth
being exact about because the cost is asymmetric and it is not obvious which direction is
which.

### InkTree into DailyCare is safe

Stories, prompts, family-authored content, anything InkTree holds — none of it becomes
protected health information by arriving in DailyCare. It lands inside DailyCare's controls
and is governed by them from that moment. Nothing about InkTree changes.

This direction can be built whenever it is wanted.

### DailyCare into InkTree drags nine services into scope

The moment a resident's name, a mood, a care note, a medication status or a photograph
crosses into InkTree, every part of InkTree that can reach it is handling PHI. Not just the
service that received it: the bus it travelled on, the services subscribed to that channel,
their logs, their backups, the model provider in the voice pipeline, the voice provider
itself, and every one of those vendors' own subprocessors.

That is not a reason never to do it. It is a reason to decide it deliberately, because the
work it creates is an order of magnitude larger than the feature that motivated it, and the
work lands on a system that did not previously need it.

**The evening phone call is this, exactly.** "Cathy had a difficult night" spoken down a
phone line is health information about a named person, passing through a model provider and
a voice provider. It needs an agreement with both, PHI-safe handling inside the voice
pipeline, and an audit trail of who was told what. All of that is buildable. None of it is
free, and none of it can be retrofitted after the first call.

### Decided, on 16 September 2026

Trevor's answer: InkTree content — stories, photographs and family context — flows into
DailyCare so a caregiver knows who they are looking after, and eventually to support
reminiscence. Nothing flows back at this stage, and the boundary should be designed so the
direction can be revisited on purpose rather than crossed by accident.

That is built, in `boundary.sql`, and there are two things worth adding to it that are not
obvious from the decision itself.

**The accident is unlikely to be a payload.** The field guide says every InkTree service
reads and writes one PostgreSQL instance directly, with no events in between — so there is
no service-level isolation over there to rely on. The cheapest and most natural thing
anybody could propose is a DailyCare schema in that instance, and the moment it exists,
nine services and their vendors are handling PHI with nothing published to say so. The
boundary therefore includes a check that this database has not been joined to another one:
no foreign data wrapper, no dblink, no foreign server.

**Reminiscence is the feature that reverses it.** Show a story, record how the resident
responded, send the response back so the next story is chosen better. The third step is a
resident's reaction to a memory leaving the agreement boundary, and nobody in the room
would describe it as sending PHI to a vendor — they would describe it as better
recommendations. `content_responses` exists, is classified as PHI, and no outbound channel
may reference it. A check adds it to a payload and watches the view report it.

**And even the narrowest outbound channel crosses the line.** A pseudonym plus a timestamp
is a code derived from a patient identifier, which Safe Harbor excludes from
de-identification. So the one outbound channel anybody has thought of is written down,
shut, and marked as requiring an agreement rather than a configuration change. Writing it
down while shut is the point: the shape of a reversal exists before somebody needs it in a
hurry.

### What to build instead, if the valve should stay one-way

Have DailyCare emit events that carry no clinical content: a facility-scoped identifier, a
resident's generated uuid, and the fact that something happened. InkTree can know that
there is an update without knowing what it says. When a family member wants to read it,
they read it from DailyCare, authenticated as themselves, inside the controls that already
exist — the same path the mobile app uses.

That keeps every clinical field inside one agreement boundary, and it costs a redirect.

---

## What survives every decision above

Worth stating plainly, because it is the answer to "have we just built something that the
Go decision throws away".

Nothing in this directory depends on the backend language, the number of services, the
presence of a bus, or whether there is a web build. The data model, the three roles as
row-level security, the audit triggers, the PHI classification, retention and deletion, the
non-production scrub, the vendor register, the backup policy and the restore gate are all
PostgreSQL. A Go handler and a TypeScript handler connect to the same database, as the same
role, under the same policies, and get the same answers.

The 319 checks run against the database, not against an application. They will still run,
and still pass, whichever way the decisions below go.

---

## Decisions needed, and from whom

| | Who decides | Why it is blocking |
|---|---|---|
| Backend language: Go or TypeScript | Trevor | Shapes the M3 estimate and who can maintain it |
| One service now, events shaped for a bus later | Trevor | Cheap to agree now, expensive to retrofit |
| Whether DailyCare data ever flows into InkTree | Trevor | Decides whether nine services enter HIPAA scope |
| Whether a voice update to family is wanted | Trevor | Needs two more agreements and a scoped design |
| GCP project, billing account and IAM | Trevor | Blocks the platform agreement, and everything after it |
| Shared identity between the two products | Later | Not needed until a person holds both accounts |
