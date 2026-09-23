#!/usr/bin/env bash
#
# Build the migration image, push it, and run it as a job inside the VPC.
#
#   ./run.sh dev            apply the model
#   ./run.sh dev --verify   and then run the suites against the instance
#
# Everything it needs is read from Terraform's outputs rather than typed here, so this
# cannot be pointed at an instance the infrastructure does not know about.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENVIRONMENT="${1:-}"
[ -n "$ENVIRONMENT" ] || { echo "usage: $0 <dev|staging> [--verify]" >&2; exit 2; }
VERIFY=0
[ "${2:-}" = "--verify" ] && VERIFY=1

cd "$HERE/$ENVIRONMENT" 2>/dev/null || cd "$HERE/../$ENVIRONMENT"
INSTANCE="$(terraform output -raw instance_connection_name)"
PROJECT="${INSTANCE%%:*}"
cd "$HERE"

# The same guard deploy.sh has, and this did not. An image tagged with a commit has to
# actually be that commit, or the tag is worse than the timestamp it replaced: it looks
# like it can be traced back. migrate:b264e1d was built from a tree with edits in it
# before this was here.
if [ -n "$(git -C "$HERE/../.." status --porcelain)" ]; then
  echo "the working tree has uncommitted changes, so a commit tag would be a lie." >&2
  echo "commit them, or stash them, and run this again." >&2
  exit 1
fi

TAG="$(git -C "$HERE/../.." rev-parse --short HEAD)"
IMAGE="us-central1-docker.pkg.dev/$PROJECT/dc-$ENVIRONMENT-docker/migrate:$TAG"

# The model as it is in the working tree, not a copy kept beside this file. A container
# that applies a different copy is the thing all of this is meant to prevent.
rm -rf "$HERE/architecture"
cp -r "$HERE/../../docs/architecture" "$HERE/architecture"
# Every entrypoint, not the two this script happened to need first. Each job overrides
# the command, so one image serves all of them - and when it did not, the reset and seed
# jobs ended up pinned to one-off tags built by hand, which is how a job comes to be
# running a copy of the model nobody can name.
cp "$HERE"/*-entrypoint.sh "$HERE/entrypoint.sh" "$HERE/architecture/"
trap 'rm -rf "$HERE/architecture"' EXIT

docker build -t "$IMAGE" "$HERE"
docker push "$IMAGE"

echo "built $IMAGE"
echo "the job still has to be created or updated, and the elevated login borrowed and"
echo "rotated - see README.md. Neither is automated on purpose: both are decisions."
