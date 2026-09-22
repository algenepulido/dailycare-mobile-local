#!/usr/bin/env bash
#
# Secrets and service accounts. A project policy says nothing about either - each carries
# its own - so without this the two narrowest grants in the whole design are declared and
# never checked: which secret the api may read, and whose token it may mint.
#
#   ./load-resource-policies.sh dev inktree-dailycare-dev > r.sql
#
# Prints SQL, touches no database, refuses to emit an empty file.

set -euo pipefail
ENVIRONMENT="${1:-}"; PROJECT="${2:-}"
[ -n "$ENVIRONMENT" ] && [ -n "$PROJECT" ] || {
  echo "usage: $0 <dev|staging|prod> <project-id>" >&2; exit 2; }
command -v gcloud >/dev/null || { echo "gcloud is not on the path" >&2; exit 1; }

sq () { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"; }

emit () {  # kind, ref, policy-json
  printf '%s' "$3" | python3 -c '
import json, re, sys
env, kind, ref = sys.argv[1], sys.argv[2], sys.argv[3]
def sql(s): return "'"'"'" + s.replace("'"'"'", "'"'"''"'"'") + "'"'"'"
out = []
for b in json.load(sys.stdin).get("bindings", []):
    for m in b.get("members", []):
        p = m.split(":", 1)[1] if ":" in m else m
        if m.startswith("serviceAccount:"):
            p = p.split("@")[0]
        agent = bool(re.match(r"^serviceAccount:service-\d+@", m))
        out.append("  (%s, %s, %s, %s, %s, %s, %s)" % (
            sql(env), sql(p), sql(b["role"]), sql(kind), sql(ref),
            "true" if b.get("condition") else "false", "true" if agent else "false"))
print(",\n".join(out))
' "$ENVIRONMENT" "$1" "$2"
}

rows=""; obs=""
add () {  # kind, ref, json, source
  local new; new="$(emit "$1" "$2" "$3")"
  [ -n "$new" ] || return 0   # a resource nobody has granted on is a real answer
  obs="${obs}INSERT INTO gcp_iam_observations (environment, scope_kind, scope_ref, source) VALUES ($(sq "$ENVIRONMENT"), $(sq "$1"), $(sq "$2"), $(sq "$4"));
"
  rows="${rows}${rows:+,
}${new}"
}

for s in $(gcloud secrets list --project="$PROJECT" --format="value(name)"); do
  add secret "$s" "$(gcloud secrets get-iam-policy "$s" --project="$PROJECT" --format=json)" \
      "gcloud secrets get-iam-policy $s"
done

for sa in $(gcloud iam service-accounts list --project="$PROJECT" --format="value(email)" \
            | grep "^dc-"); do
  add service_account "${sa%%@*}" \
      "$(gcloud iam service-accounts get-iam-policy "$sa" --project="$PROJECT" --format=json)" \
      "gcloud iam service-accounts get-iam-policy $sa"
done

[ -n "$rows" ] || { echo "nothing came back from any secret or service account" >&2; exit 1; }

echo "-- Secret and service-account policies from $PROJECT at $(date -u +%Y-%m-%dT%H:%M:%SZ)."
echo "BEGIN;"
echo "DELETE FROM gcp_iam_observed     WHERE environment = $(sq "$ENVIRONMENT") AND scope_kind IN ('secret','service_account');"
echo "DELETE FROM gcp_iam_observations WHERE environment = $(sq "$ENVIRONMENT") AND scope_kind IN ('secret','service_account');"
printf '%s' "$obs"
echo "INSERT INTO gcp_iam_observed"
echo "  (environment, principal, role, scope_kind, scope_ref, has_condition, google_managed)"
echo "VALUES"
echo "$rows;"
echo "COMMIT;"
