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
# The short name the resources carry, read from Terraform rather than taken from the
# directory this script was pointed at. They match for dev and they do not for staging,
# where everything is dc-stg-*: four lines below took the directory name and would have
# looked for dc-staging-docker, dc-staging-api and dc-staging-bootstrap, none of which
# exist.
ENV_SHORT="$(terraform output -raw environment 2>/dev/null || echo "$ENVIRONMENT")"
cd "$HERE"

if [ -n "$(git -C "$HERE/.." status --porcelain)" ]; then
  echo "the working tree has uncommitted changes, so a commit tag would be a lie." >&2
  echo "commit them, or stash them, and run this again." >&2
  exit 1
fi

TAG="$(git -C "$HERE/.." rev-parse --short HEAD)"
IMAGE="$REGION-docker.pkg.dev/$PROJECT/dc-$ENV_SHORT-docker/api:$TAG"
SERVICE="dc-$ENV_SHORT-api"

docker build -t "$IMAGE" "$HERE"
docker push "$IMAGE"

gcloud run services update "$SERVICE" \
  --image "$IMAGE" --project "$PROJECT" --region "$REGION" --quiet

# Every job running this image moves with it.
#
# dc-dev-bootstrap is the API's own binary - the account it creates has to be hashed by
# the code that verifies it - and its image was set by hand once and then left behind. It
# ran with an old build, could not see the environment variables the newer one reads, and
# reported that its arguments were missing. The job and the service are the same program
# and there is no version of this where they should differ.
for job in "dc-$ENV_SHORT-bootstrap"; do
  if gcloud run jobs describe "$job" --project "$PROJECT" --region "$REGION" >/dev/null 2>&1; then
    gcloud run jobs update "$job" --image "$IMAGE" \
      --project "$PROJECT" --region "$REGION" --quiet >/dev/null
    echo "$job is on $TAG"
  fi
done

echo ""
echo "$SERVICE is on $TAG"
echo "the revision serving traffic:"
gcloud run services describe "$SERVICE" --project "$PROJECT" --region "$REGION" \
  --format='value(status.traffic[0].revisionName)'
