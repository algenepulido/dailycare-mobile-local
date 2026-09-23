# The model, and enough PostgreSQL to apply it.
#
# The instance has no public address, so nothing outside the VPC can reach it - including
# a laptop with the right credentials, which was confirmed rather than assumed: the Cloud
# SQL proxy authenticates, listens and accepts the connection, then goes nowhere. That is
# the design working.
#
# So migrations run as a Cloud Run job on the connector. Which is where they belong anyway:
# a migration that only runs from somebody's machine is a migration that runs differently
# depending on whose machine it was.

FROM postgres:14-bookworm

# The same files verify.sh runs its checks against, applied by the same migrate.sh.
# Nothing is rebuilt for the occasion - a container that applies a different copy of the
# model is the thing this is supposed to prevent.
COPY architecture /model

# psql, createdb and bash are all in the base image. Nothing else is needed, and a smaller
# base would mean carrying a PostgreSQL client from somewhere else and hoping the versions
# agree with the server.

WORKDIR /model
ENTRYPOINT ["/model/entrypoint.sh"]
