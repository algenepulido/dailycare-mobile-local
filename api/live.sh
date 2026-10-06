#!/usr/bin/env bash
#
# Press the administrative endpoints over HTTP, against a real database with the model
# applied and the real server binary. Nothing here calls a Go function: every line is a
# request a client could make, in the order a care manager would make them.
#
#   ./live.sh

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCH="$HERE/../docs/architecture"
NAME="dailycare-live"
PORT=55433
API=8099

PASS=0; FAIL=0
say () { printf '  %-62s %s\n' "$1" "$2"; }
want () { # want <label> <expected status> <actual status> [body]
  if [ "$2" = "$3" ]; then say "$1" "ok  $3"; PASS=$((PASS+1));
  else say "$1" "FAIL expected $2, got $3"; [ -n "${4:-}" ] && echo "      $4"; FAIL=$((FAIL+1)); fi
}

docker rm -f "$NAME" >/dev/null 2>&1
docker run -d --rm --name "$NAME" -p $PORT:5432 -e POSTGRES_PASSWORD=postgres \
  -v "$ARCH":/sql:ro postgres:14 >/dev/null || exit 1
trap 'docker rm -f "$NAME" >/dev/null 2>&1; kill %1 2>/dev/null' EXIT

until docker exec "$NAME" psql -U postgres -c "select 1" >/dev/null 2>&1; do sleep 1; done
docker exec -u postgres "$NAME" createdb dailycare >/dev/null || exit 1
docker exec -u postgres -w /sql "$NAME" ./migrate.sh -d dailycare --with-roles >/dev/null || {
  echo "the model would not apply" >&2; exit 1; }
docker exec -u postgres "$NAME" psql -q -d dailycare \
  -c "ALTER ROLE dailycare_app LOGIN PASSWORD 'test'" >/dev/null || exit 1

# A building and the people in it, seeded as the owner because that is the one thing still
# outside the application: somebody has to exist before anybody can be invited. No password
# is seeded - each of them arrives through the same invitation the application now issues,
# which is both more honest and one less thing in this script that could be wrong on its own.
link () { head -c 24 /dev/urandom | base64 | tr -d '=+/' ; }
digest () { printf '%s' "$1" | sha256sum | cut -d' ' -f1 ; }
L_PRIYA=$(link); L_MARIA=$(link); L_BEN=$(link)
docker exec -i -u postgres "$NAME" psql -q -d dailycare -v ON_ERROR_STOP=1 <<SQL >/dev/null || exit 1
INSERT INTO facilities (id, name, timezone) VALUES
  ('f1000000-0000-0000-0000-000000000001', 'Cedar House', 'America/Chicago'),
  ('f2000000-0000-0000-0000-000000000002', 'Birch House', 'America/Chicago');
INSERT INTO users (id, email, display_name) VALUES
  ('b0000000-0000-0000-0000-00000000000b', 'priya@example.test', 'Priya'),
  ('a0000000-0000-0000-0000-00000000000a', 'maria@example.test', 'Maria'),
  ('d0000000-0000-0000-0000-00000000000d', 'ben@example.test',   'Ben');
INSERT INTO user_tokens (user_id, purpose, token_hash, expires_at) VALUES
  ('b0000000-0000-0000-0000-00000000000b','invitation','$(digest "$L_PRIYA")', now() + interval '1 day'),
  ('a0000000-0000-0000-0000-00000000000a','invitation','$(digest "$L_MARIA")', now() + interval '1 day'),
  ('d0000000-0000-0000-0000-00000000000d','invitation','$(digest "$L_BEN")',   now() + interval '1 day');
INSERT INTO facility_members (id, facility_id, user_id, role, state) VALUES
  ('fb000000-0000-0000-0000-00000000000b', 'f1000000-0000-0000-0000-000000000001',
   'b0000000-0000-0000-0000-00000000000b', 'care_manager', 'active'),
  ('fa000000-0000-0000-0000-00000000000a', 'f1000000-0000-0000-0000-000000000001',
   'a0000000-0000-0000-0000-00000000000a', 'caregiver', 'active'),
  ('fd000000-0000-0000-0000-00000000000d', 'f2000000-0000-0000-0000-000000000002',
   'd0000000-0000-0000-0000-00000000000d', 'care_manager', 'active');
SQL

export DATABASE_URL="postgres://dailycare_app:test@127.0.0.1:$PORT/dailycare?sslmode=disable"
export JWT_SIGNING_KEY="a-signing-key-for-this-run-only-that-is-long-enough"
export PORT=$API
(cd "$HERE" && go run . >/tmp/dailycare-live.log 2>&1) &
for _ in $(seq 1 40); do
  curl -sf "http://127.0.0.1:$API/v1/health" >/dev/null 2>&1 && break
  sleep 1
done
curl -sf "http://127.0.0.1:$API/v1/health" >/dev/null 2>&1 || {
  echo "the server did not come up:"; tail -6 /tmp/dailycare-live.log; exit 1; }

req () { # req <method> <path> <token> [body] -> prints "STATUS<tab>BODY"
  local m=$1 p=$2 t=$3 b=${4:-}
  if [ -n "$b" ]; then
    curl -s -o /tmp/dc-body -w '%{http_code}' -X "$m" "http://127.0.0.1:$API$p" \
      -H "Authorization: Bearer $t" -H 'Content-Type: application/json' -d "$b"
  else
    curl -s -o /tmp/dc-body -w '%{http_code}' -X "$m" "http://127.0.0.1:$API$p" \
      -H "Authorization: Bearer $t"
  fi
  printf '\t'; cat /tmp/dc-body
}

field () { python3 -c "
import json,sys
try:  d=json.load(open('/tmp/dc-body'))
except Exception: print(''); sys.exit()
for k in '$1'.split('.'):
    if not isinstance(d, dict): print(''); sys.exit()
    d = d.get(k)
    if d is None: print(''); sys.exit()
print(d)"; }

arrive () { # arrive <link> <password> -> prints the access token
  curl -s -o /tmp/dc-body -w '%{http_code}' -X POST "http://127.0.0.1:$API/v1/credentials" \
    -H 'Content-Type: application/json' \
    -d "{\"link\":\"$1\",\"password\":\"$2\",\"device\":\"live\"}" >/dev/null
  field accessToken
}

echo
echo "── everybody arrives through their invitation"
OUT=$(curl -s -o /tmp/dc-body -w '%{http_code}' -X POST "http://127.0.0.1:$API/v1/credentials" \
  -H 'Content-Type: application/json' \
  -d "{\"link\":\"$L_PRIYA\",\"password\":\"a reasonable passphrase\",\"device\":\"live\"}")
want "a care manager sets their own password from a link" 201 "$OUT" "$(cat /tmp/dc-body)"
PRIYA=$(field accessToken)
MARIA=$(arrive "$L_MARIA" "a reasonable passphrase")
BEN=$(arrive "$L_BEN" "a reasonable passphrase")

CEDAR=f1000000-0000-0000-0000-000000000001
BIRCH=f2000000-0000-0000-0000-000000000002

echo
echo "── the building as it stands"
R=$(req GET "/v1/facilities/$CEDAR/members" "$PRIYA"); S=${R%%$'\t'*}; B=${R#*$'\t'}
want "a manager reads their own building" 200 "$S" "$B"
echo "      $(python3 -c '
import json
d=json.load(open("/tmp/dc-body"))
print(", ".join(m["displayName"]+" ("+m["role"]+", "+m["state"]+")" for m in d) if isinstance(d,list) else d)')"

echo
echo "── inviting a caregiver"
R=$(req POST "/v1/facilities/$CEDAR/members" "$PRIYA" \
  '{"email":"tomas@example.test","displayName":"Tomas","role":"caregiver"}')
S=${R%%$'\t'*}; B=${R#*$'\t'}
want "a manager invites somebody into their building" 201 "$S" "$B"
LINK=$(field link)
TOMAS_M=$(field member.id)
STATE=$(field member.state)
want "and the membership opens invited" invited "$STATE"
[ -n "$LINK" ] && want "and a link comes back exactly once" yes yes || want "and a link comes back exactly once" yes no

echo
echo "── the invited caregiver arrives on their own"
OUT=$(curl -s -o /tmp/dc-body -w '%{http_code}' -X POST "http://127.0.0.1:$API/v1/credentials" \
  -H 'Content-Type: application/json' \
  -d "{\"link\":\"$LINK\",\"password\":\"another reasonable passphrase\",\"device\":\"tomas phone\"}")
want "they set their own password from the link" 201 "$OUT" "$(cat /tmp/dc-body)"

OUT=$(curl -s -o /tmp/dc-body -w '%{http_code}' -X POST "http://127.0.0.1:$API/v1/sessions" \
  -H 'Content-Type: application/json' \
  -d '{"email":"tomas@example.test","password":"another reasonable passphrase","device":"tomas phone"}')
want "and sign in" 201 "$OUT" "$(cat /tmp/dc-body)"
TOMAS=$(field accessToken)

R=$(req GET "/v1/facilities/$CEDAR/members" "$TOMAS"); S=${R%%$'\t'*}
want "and the building is theirs to see now" 200 "$S"
ACTIVE=$(python3 -c "
import json
d=json.load(open('/tmp/dc-body'))
print(next((m['state'] for m in d if m['id']=='$TOMAS_M'),'missing') if isinstance(d,list) else 'not a list')")
want "accepting moved the membership to active" active "$ACTIVE"

echo
echo "── what a caregiver may not do"
R=$(req POST "/v1/facilities/$CEDAR/members" "$MARIA" \
  '{"email":"nope@example.test","displayName":"Nope","role":"caregiver"}')
want "a caregiver cannot invite anybody" 403 "${R%%$'\t'*}" "${R#*$'\t'}"

R=$(req DELETE "/v1/members/fb000000-0000-0000-0000-00000000000b" "$MARIA")
want "and cannot end their manager's membership" 403 "${R%%$'\t'*}" "${R#*$'\t'}"
grep -q "last care manager" /tmp/dc-body && { say "and is not told who the last manager is" "FAIL leaked"; FAIL=$((FAIL+1)); } \
  || { say "and is not told who the last manager is" "ok"; PASS=$((PASS+1)); }

echo
echo "── what a manager may not do"
R=$(req POST "/v1/facilities/$BIRCH/members" "$PRIYA" \
  '{"email":"nope2@example.test","displayName":"Nope","role":"caregiver"}')
want "a manager cannot reach another building" 403 "${R%%$'\t'*}" "${R#*$'\t'}"

R=$(req DELETE "/v1/members/fd000000-0000-0000-0000-00000000000d" "$PRIYA")
want "and a membership there is not even visible" 404 "${R%%$'\t'*}" "${R#*$'\t'}"

R=$(req DELETE "/v1/members/fb000000-0000-0000-0000-00000000000b" "$PRIYA")
want "and cannot leave the building with nobody to run it" 409 "${R%%$'\t'*}" "${R#*$'\t'}"

R=$(req POST "/v1/facilities/$CEDAR/members" "$PRIYA" \
  '{"email":"tomas@example.test","displayName":"Tomas","role":"caregiver"}')
want "and cannot make a second account on one address" 409 "${R%%$'\t'*}" "${R#*$'\t'}"

echo
echo "── ending a membership"
R=$(req DELETE "/v1/members/$TOMAS_M" "$PRIYA")
want "a manager ends a membership" 204 "${R%%$'\t'*}" "${R#*$'\t'}"

R=$(req GET "/v1/facilities/$CEDAR/members" "$PRIYA")
ENDED=$(python3 -c "
import json
d=json.load(open('/tmp/dc-body'))
if not isinstance(d,list): print('not a list')
else:
    m=next((m for m in d if m['id']=='$TOMAS_M'),None)
    print('gone' if m is None else ('kept ' + m['state'] + (' with a date' if m.get('endedAt') else ' with no date')))")
want "and they are still in the building, with a date" "kept revoked with a date" "$ENDED"

R=$(req GET "/v1/facilities/$CEDAR/members" "$TOMAS")
want "and their phone stops seeing the building" 200 "${R%%$'\t'*}"
LEFT=$(python3 -c 'import json;d=json.load(open("/tmp/dc-body"));print(len(d) if isinstance(d,list) else -1)')
want "which now shows them nothing" 0 "$LEFT"

echo
printf '  %d passed, %d failed\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
