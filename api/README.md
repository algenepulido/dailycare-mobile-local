# The API

Go, talking to the database in `docs/architecture` as `dailycare_app` and no one else.

    ./test.sh          # builds a throwaway postgres:14, applies the model, runs the tests

## The one rule

Every request runs inside a transaction that has said who it is:

    SET LOCAL app.user_id = '<the authenticated user>'

The policies read that setting. A statement outside such a transaction sees nothing, which
is the right default and an easy one to reach by accident — a handler that forgets returns
an empty list rather than an error, and an empty list looks exactly like a resident with no
care records.

So there is no way to get a connection out of `internal/db` without saying who is asking.
The pool is unexported and `InSession` is the only way through. `Unidentified` exists for
the few things that happen before anybody is identified — looking up a session, consuming
an invitation — and it sets no identity, so the policies hide everything the application
role was not explicitly granted.

`SET LOCAL` rather than `SET`, and there is a test for it. `SET` would leave the previous
caller's identity on the pooled connection for whoever borrows it next, which under load is
one caregiver reading another's facility with nothing in the logs to say so.

## What the tests are for

Four of them, and one is about the tests themselves: that the connection is
`dailycare_app` and not a superuser or the owner. A superuser bypasses row-level security
entirely, so a suite run as one passes while proving nothing — that already happened once
here, to 193 checks, and it is the reason `verify.sh` runs as an ordinary role.

Confirmed the check fails both ways it should: as `postgres` it reports the superuser, and
as another non-superuser role it reports the wrong name.

## Reads

`audit-logging.sql` calls reads the honest gap in the design: PostgreSQL has no `SELECT`
trigger, so a read is in the audit trail only if the application says so. It calls that
"a convention the code has to keep rather than a guarantee the database enforces, and the
one place where a forgetful handler still produces a gap."

That gap lives here, so this is where it gets closed as far as it can be.

`internal/records` is the only package that reads resident data. Its unexported `read`
calls `audit_read` first, in the same transaction as the query, so a read missing from the
trail is a read that did not commit. `audit_read` also refuses to record a read of a
resident the session cannot see, which makes the access check happen before any row is
fetched rather than after.

Two tests hold the line, because a comment saying "only read through here" is a comment:

- Nothing outside the package names a PHI table in a query. The list of tables comes from
  `data_classification`, so a table added to the model next month is covered without anyone
  remembering — the same reason the completeness views are queries rather than checklists.
- Inside the package, any query that does not go through `read` has to be named in the test
  with a reason. There is one: listing residents, because the list is exactly the
  assignment and a row per resident on every app launch is the event that carries no
  information, in the volume that makes the rest unreadable.

Both were confirmed to fail: a handler with `FROM care_days` in it, and an undeclared
method that queries without auditing.

## The surface

    POST   /v1/sessions            sign in
    POST   /v1/sessions/refresh    rotate
    DELETE /v1/sessions            sign out this device
    DELETE /v1/sessions/all        sign out everywhere (identified)
    GET    /v1/residents           (identified)
    GET    /v1/residents/{id}/days/{date}   (identified)
    GET    /healthz

Three of those are unauthenticated and nothing else is. `identified` refuses anything
without a verifiable access token before the handler runs, because a handler that has to
remember to check is a handler that one day will not.

The access token is not a JWT. A JWT carries the algorithm inside the token, so the
verifier is told how to verify by the thing it is verifying — that is `alg=none` and the
RS256-to-HS256 confusion, and libraries have shipped both for a decade. One algorithm here,
not negotiable, not in the token. It carries a user and an expiry and nothing else: a role
or a facility in there would be a copy of the access model made at sign-in and stale the
moment somebody's shift changed.

## What the caller is not told

A resident you may not see and a resident who does not exist are the same 404 with the same
sentence. Otherwise a caregiver can enumerate the building by asking about uuids until the
answer changes.

An expired token and a forged one are the same 401. The client's next move is identical,
and telling the difference to somebody holding a forgery tells them the forgery was
well-formed.

Sign-in has one failure for four causes. "This address exists" is worth having if the next
step is a mail to a caregiver about a resident they know by name — so the password is
verified against a decoy digest when there is no account, and the answer takes about as
long either way.

The database's error goes to the log with the request id, never to the caller. A handler
that returns it says which table exists, which constraint was tripped, and often the value
that tripped it.

## Logging

`never_log` is computed from the classification — every phi, identifying or secret column,
minus the identifiers a log line exists to carry. The process reads it at start-up and
refuses to start if the query fails or comes back empty, because a logger that quietly fell
back to an empty list would be a logger with no rules at the moment nobody was watching.

A forbidden field keeps its name and loses its value. Dropping it entirely would leave a
line that reads as though nothing was there.
