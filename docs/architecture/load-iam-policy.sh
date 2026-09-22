#!/usr/bin/env bash
#
# Turn a real GCP policy into rows for gcp_iam_observed, so drift compares the model
# against what is granted rather than against itself.
#
#   ./load-iam-policy.sh inktree-dailycare-dev dev > dev.sql
#   psql -d dailycare -f dev.sql
#
# Emits SQL on stdout and touches no database. Nothing in this directory reaches out to
# Google: a database that can call a cloud API is a different and worse thing than one
# that cannot, and a script that prints SQL can be read before it is run.
#
# It refuses to produce an empty file. The first version did produce one - a bug in the
# Python it carried inline - and the drift report that consumed it said "no differences",
# which is the failure this whole directory is about.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="${1:-}"
ENVIRONMENT="${2:-}"
[ -n "$PROJECT" ] && [ -n "$ENVIRONMENT" ] || {
  echo "usage: $0 <project-id> <dev|staging|prod>" >&2; exit 2; }

command -v gcloud >/dev/null || { echo "gcloud is not on the path" >&2; exit 1; }

if ! POLICY="$(gcloud projects get-iam-policy "$PROJECT" --format=json 2>&1)"; then
  {
    echo "could not read the policy for $PROJECT:"
    printf '%s\n' "$POLICY" | head -3
    echo
    echo "Reading a project's policy needs resourcemanager.projects.getIamPolicy. The"
    echo "deploy-only role set does not carry it, so staging cannot be checked by us as"
    echo "things stand - either it gets granted or somebody else runs this. Do not record"
    echo "the environment as checked."
  } >&2
  exit 1
fi

printf '%s' "$POLICY" | "$HERE/iam-policy-to-sql.py" "$PROJECT" "$ENVIRONMENT"
