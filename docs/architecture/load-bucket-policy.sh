#!/usr/bin/env bash
#
# The bucket half of the same job load-iam-policy.sh does for a project.
#
#   ./load-bucket-policy.sh dev inktree-dailycare-dev-media inktree-dailycare-dev-backup > b.sql
#
# A project policy says nothing about a bucket - each carries its own - so without this the
# object roles that are the retention handshake are declared and never checked. Same rule:
# prints SQL, touches no database, refuses to emit an empty file.

set -euo pipefail
ENVIRONMENT="${1:-}"; shift || true
[ -n "$ENVIRONMENT" ] && [ $# -gt 0 ] || {
  echo "usage: $0 <dev|staging|prod> <bucket> [bucket...]" >&2; exit 2; }

command -v gcloud >/dev/null || { echo "gcloud is not on the path" >&2; exit 1; }

sq () { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"; }

rows=""
observations=""
for bucket in "$@"; do
  if ! policy="$(gcloud storage buckets get-iam-policy "gs://$bucket" --format=json 2>&1)"; then
    echo "could not read the policy for gs://$bucket:" >&2
    printf '%s\n' "$policy" | head -3 >&2
    exit 1
  fi
  observations="${observations}INSERT INTO gcp_iam_observations (environment, scope_kind, scope_ref, source) VALUES ($(sq "$ENVIRONMENT"), 'bucket', $(sq "$bucket"), $(sq "gcloud storage buckets get-iam-policy gs://$bucket"));
"
  new="$(printf '%s' "$policy" | python3 -c '
import json, re, sys
env, bucket = sys.argv[1], sys.argv[2]
def sql(s): return "'"'"'" + s.replace("'"'"'", "'"'"''"'"'") + "'"'"'"
out = []
for b in json.load(sys.stdin).get("bindings", []):
    role = b["role"]
    for m in b.get("members", []):
        if m.startswith("serviceAccount:"):
            principal = m[len("serviceAccount:"):].split("@")[0]
        elif m.startswith("user:"):
            principal = m[len("user:"):]
        else:
            principal = m
        agent = bool(re.match(r"^(projectOwner|projectEditor|projectViewer):", m)
                     or role.endswith("ServiceAgent") or role.endswith(".serviceAgent")
                     or re.match(r"^serviceAccount:service-\d+@", m))
        out.append("  (%s, %s, %s, %s, %s, false, %s)" % (
            sql(env), sql(principal), sql(role), sql("bucket"), sql(bucket),
            "true" if agent else "false"))
print(",\n".join(out))
' "$ENVIRONMENT" "$bucket")"
  [ -n "$new" ] || { echo "gs://$bucket returned no bindings, which is not a thing a real bucket does" >&2; exit 1; }
  rows="${rows}${rows:+,
}${new}"
done

echo "-- Read from $# bucket policies at $(date -u +%Y-%m-%dT%H:%M:%SZ)."
echo "BEGIN;"
for bucket in "$@"; do
  echo "DELETE FROM gcp_iam_observed WHERE environment = $(sq "$ENVIRONMENT") AND scope_kind = 'bucket' AND scope_ref = $(sq "$bucket");"
  echo "DELETE FROM gcp_iam_observations WHERE environment = $(sq "$ENVIRONMENT") AND scope_kind = 'bucket' AND scope_ref = $(sq "$bucket");"
done
printf '%s' "$observations"
echo "INSERT INTO gcp_iam_observed"
echo "  (environment, principal, role, scope_kind, scope_ref, has_condition, google_managed)"
echo "VALUES"
echo "$rows;"
echo "COMMIT;"
