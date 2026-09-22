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

TAG="$(git -C "$HERE/../.." rev-parse --short HEAD)"
IMAGE="us-central1-docker.pkg.dev/$PROJECT/dc-$ENVIRONMENT-docker/migrate:$TAG"

# The model as it is in the working tree, not a copy kept beside this file. A container
# that applies a different copy is the thing all of this is meant to prevent.
rm -rf "$HERE/architecture"
cp -r "$HERE/../../docs/architecture" "$HERE/architecture"
cp "$HERE/entrypoint.sh" "$HERE/verify-entrypoint.sh" "$HERE/architecture/"
trap 'rm -rf "$HERE/architecture"' EXIT

docker build -t "$IMAGE" "$HERE"
docker push "$IMAGE"

echo "built $IMAGE"
echo "the job still has to be created or updated, and the elevated login borrowed and"
echo "rotated - see README.md. Neither is automated on purpose: both are decisions."
