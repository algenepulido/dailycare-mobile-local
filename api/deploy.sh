#!/usr/bin/env bash
#
# Build the API, push it, and point the Cloud Run service at it.
#
#   ./deploy.sh dev
#
# The image is tagged with the commit it was built from. It was not, and the service ended
# up running api:h-1790174785 - a tag that says when somebody typed a command and nothing
# about which code it holds. The same thing had happened to two of the migration jobs.
#
# Only the image is changed. Environment, secrets, the connector, the service account and
# the scaling are Terraform's and this does not touch them: a deploy that can quietly
# rewrite how the service reaches its database is a deploy that will, on the day somebody
# is in a hurry.
#
# A dirty tree stops it. An image tagged with a commit has to actually be that commit,
# otherwise the tag is worse than the timestamp it replaced - it looks trustworthy.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENVIRONMENT="${1:-}"
[ -n "$ENVIRONMENT" ] || { echo "usage: $0 <dev|staging>" >&2; exit 2; }

cd "$HERE/../infra/$ENVIRONMENT"
INSTANCE="$(terraform output -raw instance_connection_name)"
PROJECT="${INSTANCE%%:*}"
REGION="${INSTANCE#*:}"; REGION="${REGION%%:*}"
cd "$HERE"

if [ -n "$(git -C "$HERE/.." status --porcelain)" ]; then
  echo "the working tree has uncommitted changes, so a commit tag would be a lie." >&2
  echo "commit them, or stash them, and run this again." >&2
  exit 1
fi

TAG="$(git -C "$HERE/.." rev-parse --short HEAD)"
IMAGE="$REGION-docker.pkg.dev/$PROJECT/dc-$ENVIRONMENT-docker/api:$TAG"
SERVICE="dc-$ENVIRONMENT-api"

docker build -t "$IMAGE" "$HERE"
docker push "$IMAGE"

gcloud run services update "$SERVICE" \
  --image "$IMAGE" --project "$PROJECT" --region "$REGION" --quiet

echo ""
echo "$SERVICE is on $TAG"
echo "the revision serving traffic:"
gcloud run services describe "$SERVICE" --project "$PROJECT" --region "$REGION" \
  --format='value(status.traffic[0].revisionName)'
