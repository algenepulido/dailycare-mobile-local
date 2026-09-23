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

## Creating a caregiver's account on a deployed instance

`dailycare-api bootstrap` needs to reach the database, and the instance has no public
address, so it runs as a job like everything else here. The job is the API image, not the
migration image: the account it creates has to be hashed by the code that will verify it.

    gcloud run jobs execute dc-dev-bootstrap --region us-central1 \
      --update-env-vars BOOTSTRAP_EMAIL=ben@cedar.test,\
    BOOTSTRAP_NAME="Ben Okafor",\
    BOOTSTRAP_FACILITY=<facility uuid>,\
    BOOTSTRAP_RESIDENTS=<resident uuid>

The invitation is on stdout in the execution's log, printed once, and only its digest is
stored — so if it is lost, the answer is another invitation rather than a lookup.

A job's command line is fixed when the job is created and `execute` can only override the
environment, which is why `bootstrap` reads both. Flags win when it is run by hand.

It connects as `postgres` through the `seed_pw` secret, like the migration jobs do. That
is the credential path Trevor is replacing with a dedicated migration identity; nothing
here removes it.
