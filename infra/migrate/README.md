# Migrations

The model goes on the instance from here, as a Cloud Run job, because it cannot go on from
anywhere else.

The instance has no public address — `sql.restrictPublicIp` leaves no other option — so
nothing outside the VPC can reach it, including a laptop with the right credentials. That
was confirmed rather than assumed: the Cloud SQL proxy authenticates, listens, accepts the
connection, and then the connection to `10.53.0.3` goes nowhere. The design working.

Which is the better arrangement anyway. A migration that only runs from somebody's machine
is a migration that runs differently depending on whose machine it was.

    ./run.sh dev                 # build, push, and apply the model
    ./run.sh dev --verify        # and run the suites against it

The image is `postgres:14-bookworm` with `docs/architecture` copied in. It applies the
model with the same `migrate.sh` that builds every test database, and the checks run
through the same `verify.sh` — there is one runner, and the first version of this
directory got that wrong by writing a second one that ran all fourteen suites against a
single database. They all seed the same fixtures; it drowned in duplicate keys.

## The elevated login

`roles.sql` needs a role that can create roles, which on Cloud SQL means `postgres`. The
job borrows it for one run through a Secret Manager secret, and the password is rotated and
the secret deleted immediately afterwards — which `migrate.sh --with-roles` prints as its
closing line, so the reminder is in the output rather than in somebody's memory.

Two things that are true about this and worth stating rather than leaving to be discovered:

The schema is owned by `postgres`, so every future migration has to borrow it again. The
right answer is an owner role of its own, created once. That is the real conclusion of the
`CREATE ROLE` question rather than a thing already solved.

And the org policy caught a mistake on the way through. The secret was first created with
automatic replication, which puts a database password in every region Google has;
`gcp.resourceLocations` refused it. It is pinned to `us-central1` now.
