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
