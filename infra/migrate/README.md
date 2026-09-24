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

It connects as the migration identity, like every other job here, and holds no password:
the token comes from the service account the job runs as. It creates the account with no
`password_hash` at all, so the invitation is the only way in until somebody accepts it.

## The postgres password, and why there isn't one

After the cutover nothing in normal operation needs it. The five jobs, the API and
bootstrap all authenticate as the service account they run as; Cloud SQL's IAM
authentication puts a short-lived token where the password goes, and there is nothing to
store, rotate, or leave in a secret nobody remembers creating.

Two things still need it, and neither is normal operation:

**iam-grant** runs `cloudsql-iam.sql`, which grants each IAM database user its model role.
That needs `CREATEROLE`, which the migration login deliberately does not have — on
PostgreSQL 14 a `CREATEROLE` role may set any non-superuser role's password, which would
make the migration identity a route to every other identity in the cluster.

**handover** moves the schema to `dailycare_owner`. Once per instance, and only the
current owner can do it.

Both are per-instance setup rather than something that runs again, so they are not left
standing wired to a credential. When a new instance is built, or a service account is
added to an existing one, recreate them:

    # A password that exists for one run.
    gcloud sql users set-password postgres --instance=dc-<env>-pg --prompt-for-password
    printf '%s' "<that password>" | gcloud secrets create <env>_bootstrap_pw --data-file=-
    gcloud secrets add-iam-policy-binding <env>_bootstrap_pw \
      --member=serviceAccount:dc-<env>-api@<project>.iam.gserviceaccount.com \
      --role=roles/secretmanager.secretAccessor

    # Then the job, from this directory's image, with --command pointing at the
    # entrypoint you need. See the two gcloud run jobs create lines in git history for
    # dc-dev-iam-grant and dc-dev-handover.

    # And afterwards, both of these:
    gcloud secrets delete <env>_bootstrap_pw
    gcloud sql users set-password postgres --instance=dc-<env>-pg --prompt-for-password

The last line is the point. The password is rotated to a value nobody keeps, so the
credential does not exist between the moments somebody deliberately creates it.

A job left wired to a secret that has been deleted goes into an error state and stays
there quietly: dc-dev-iam-grant sat like that for a day, and the refusal only surfaced
when something tried to run it. That is why these are removed rather than disabled.
