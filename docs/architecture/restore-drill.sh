#!/usr/bin/env bash
#
# Restore drill
#
# The question a reviewer actually asks about backups is whether anyone has ever restored
# one. This answers it by doing it, and by asking the two things a restore drill usually
# forgets: did the data come back, and did the copy stop being able to serve it.
#
#   ./restore-drill.sh --build              # build a source database first, then drill it
#   ./restore-drill.sh --source dailycare   # drill an existing one
#
# Needs psql, pg_dump, createdb and dropdb on the path, and a role that may create
# databases. Everything it creates, it removes.
#
# Exit code is 0 only if every assertion held.

set -uo pipefail

SOURCE=""
BUILD=0
TARGET="drill_$(date +%Y%m%d_%H%M%S)"
KEEP=0
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DUMP="$(mktemp -t dailycare-drill-XXXXXX.sql)"

while [ $# -gt 0 ]; do
  case "$1" in
    --build)  BUILD=1; SOURCE="drill_source_$$" ;;
    --source) SOURCE="$2"; shift ;;
    --target) TARGET="$2"; shift ;;
    --keep)   KEEP=1 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

[ -n "$SOURCE" ] || { echo "give --source <database> or --build" >&2; exit 2; }

for tool in psql pg_dump createdb dropdb; do
  command -v "$tool" >/dev/null || { echo "$tool is not on the path" >&2; exit 1; }
done

PASSED=0
FAILED=0
say()  { printf '%s\n' "$*"; }
pass() { PASSED=$((PASSED+1)); printf 'PASS  %s\n' "$*"; }
fail() { FAILED=$((FAILED+1)); printf 'FAIL  %s\n' "$*"; }
check(){ # check "label" expected actual
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected $2, got $3)"; fi
}
q()    { psql -qAt -d "$1" -c "$2" 2>/dev/null; }

cleanup() {
  rm -f "$DUMP" "$DUMP.err"
  if [ "$KEEP" = 0 ]; then
    dropdb --if-exists "$TARGET" >/dev/null 2>&1
    [ "$BUILD" = 1 ] && dropdb --if-exists "$SOURCE" >/dev/null 2>&1
  fi
}
trap cleanup EXIT

CANARY="DRILL-CANARY-$(date +%s)"

# ── a source database with something in it worth losing ────────────────────────

if [ "$BUILD" = 1 ]; then
  say "building $SOURCE"
  createdb "$SOURCE" || exit 1
  for f in schema.sql agreements.sql incidents.sql authentication.sql access-policies.sql identity-policies.sql \
           emergency-and-program.sql data-classification.sql access-matrix.sql audit-logging.sql \
           retention.sql environments.sql vendors.sql backup-recovery.sql \
           phi-safe-logging.sql encryption-and-secrets.sql boundary.sql grants.sql \
           checks-support.sql; do
    psql -q -v ON_ERROR_STOP=1 -d "$SOURCE" -f "$HERE/$f" >/dev/null || {
      echo "could not apply $f" >&2; exit 1; }
  done
  psql -q -v ON_ERROR_STOP=1 -d "$SOURCE" >/dev/null <<SQL || exit 1
SELECT checks_begin();
GRANT USAGE ON SCHEMA public TO dailycare_app;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO dailycare_app;
REVOKE ALL ON deployment, scrub_rules, scrub_runs, vendors, vendor_exposure,
  backup_policies, restore_drills FROM dailycare_app;
GRANT SELECT ON deployment TO dailycare_app;

INSERT INTO deployment (environment, label) VALUES ('production', 'drill source');
INSERT INTO facilities (id, name, timezone)
  VALUES ('f1000000-0000-0000-0000-000000000001','Cedar House','America/Chicago');
INSERT INTO retention_policies (facility_id, care_record_days, media_days, audit_days, care_record_basis)
  VALUES ('f1000000-0000-0000-0000-000000000001', 2555, 2555, 2190, 'State long-term-care record retention, fixture value');
INSERT INTO users (id, email, display_name)
  VALUES ('a0000000-0000-0000-0000-00000000000a','maria@cedar.test','Maria');
INSERT INTO facility_members (id, facility_id, user_id, role, state)
  VALUES ('fa000000-0000-0000-0000-00000000000a','f1000000-0000-0000-0000-000000000001',
          'a0000000-0000-0000-0000-00000000000a','care_manager','active');
INSERT INTO residents (id, facility_id, display_name)
  VALUES ('e1000000-0000-0000-0000-000000000001','f1000000-0000-0000-0000-000000000001',
          'Cathy Mulholland');
INSERT INTO care_days (facility_id, resident_id, care_date, mood, appetite, sleep, note, filed_by)
  VALUES ('f1000000-0000-0000-0000-000000000001','e1000000-0000-0000-0000-000000000001',
          current_date,'agitated','refused','didnt_sleep',
          'She was frightened again tonight. $CANARY',
          'a0000000-0000-0000-0000-00000000000a');
SELECT checks_end();
SQL
else
  CANARY="$(q "$SOURCE" "SELECT note FROM care_days WHERE note <> '' LIMIT 1")"
fi

SRC_RESIDENTS=$(q "$SOURCE" "SELECT count(*) FROM residents")
SRC_CAREDAYS=$(q "$SOURCE" "SELECT count(*) FROM care_days")
say ""
say "── source: $SOURCE — $SRC_RESIDENTS residents, $SRC_CAREDAYS care days"

# What the application can read there, which is the thing being restored.
SRC_VISIBLE=$(psql -qAt -d "$SOURCE" 2>/dev/null <<SQL
SET ROLE dailycare_app;
SELECT set_config('app.user_id','a0000000-0000-0000-0000-00000000000a',false);
SELECT count(*) FROM care_days;
SQL
)
SRC_VISIBLE=$(printf '%s\n' "$SRC_VISIBLE" | tail -1)
check "the application can read the source" "$SRC_CAREDAYS" "$SRC_VISIBLE"

# ── dump and restore ───────────────────────────────────────────────────────────

say ""
say "── restoring into $TARGET"
SRC_FORCED=$(q "$SOURCE" "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relrowsecurity AND c.relforcerowsecurity")
STARTED=$(date +%s)

# FORCE row-level security applies to the owner, so pg_dump run as the owner fails on every
# PHI table. That is the right failure - the alternative, --enable-row-security, succeeds
# while dumping only the rows the policies admit, which is a partial backup that looks
# complete. In production the export is taken by a role that bypasses row-level security,
# or by the platform's snapshot mechanism, which works below this layer entirely.
if ! pg_dump -d "$SOURCE" -f "$DUMP" 2>"$DUMP.err"; then
  if grep -q 'row-level security' "$DUMP.err"; then
    say "   pg_dump refused while FORCE row-level security is on, which is correct."
    say "   lifting it on the source for the duration of the export"
    psql -qAt -d "$SOURCE" -c 'SELECT checks_begin();' >/dev/null 2>&1 || {
      fail "pg_dump needs a role with BYPASSRLS, or checks-support.sql on the source"; exit 1; }
    pg_dump -d "$SOURCE" -f "$DUMP" || { fail "pg_dump"; exit 1; }
    psql -qAt -d "$SOURCE" -c 'SELECT checks_end();' >/dev/null 2>&1
    pass "the export refuses to run silently partial"
  else
    fail "pg_dump"; sed 's/^/    /' "$DUMP.err"; exit 1
  fi
fi
rm -f "$DUMP.err"
createdb "$TARGET" || { fail "createdb"; exit 1; }
psql -q -v ON_ERROR_STOP=1 -d "$TARGET" -f "$DUMP" >/dev/null 2>"$DUMP.err" || {
  fail "restore"; grep -E 'ERROR' "$DUMP.err" | head -5 | sed 's/^/    /'; exit 1; }
ELAPSED=$(( ($(date +%s) - STARTED + 59) / 60 ))

# A dump taken with FORCE lifted restores a database where the owner is no longer subject
# to the policies. The copy would be weaker than the original and nothing would say so, so
# the first thing the drill does after a restore is put it back and check that it matches.
psql -qAt -d "$TARGET" -c 'SELECT checks_end();' >/dev/null 2>&1
TGT_FORCED=$(q "$TARGET" "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relrowsecurity AND c.relforcerowsecurity")
check "the copy forces row-level security on the same tables as the source" "$SRC_FORCED" "$TGT_FORCED"

# And lifted again, deliberately, for this script's own reads. Everything that tests a
# policy below does it by becoming dailycare_app, not by reading as the owner.
psql -qAt -d "$TARGET" -c 'SELECT checks_begin();' >/dev/null 2>&1

check "every resident came back"  "$SRC_RESIDENTS" "$(q "$TARGET" 'SELECT count(*) FROM residents')"
check "every care day came back"  "$SRC_CAREDAYS"  "$(q "$TARGET" 'SELECT count(*) FROM care_days')"

# ── and then the half a restore drill usually skips ────────────────────────────

say ""
say "── the copy"
check "it knows it is not where it was written" "f" "$(q "$TARGET" 'SELECT deployment_is_original()')"
check "and refuses to serve"                    "f" "$(q "$TARGET" 'SELECT app_data_is_servable()')"

TGT_VISIBLE=$(psql -qAt -d "$TARGET" 2>/dev/null <<SQL
SET ROLE dailycare_app;
SELECT set_config('app.user_id','a0000000-0000-0000-0000-00000000000a',false);
SELECT count(*) FROM care_days;
SQL
)
TGT_VISIBLE=$(printf '%s\n' "$TGT_VISIBLE" | tail -1)
check "the same query that read the source reads nothing here" "0" "$TGT_VISIBLE"

# The record is physically present. If it were not, the check above would be passing for
# the wrong reason and the drill would be proving nothing.
STILL_THERE=$(q "$TARGET" "SELECT count(*) FROM care_days WHERE note LIKE '%${CANARY}%'")
check "though the record is still physically there, which is what the gate is for" "1" "$STILL_THERE"

psql -qAt -d "$TARGET" -c \
  "UPDATE deployment SET environment='development', label='restore drill';" >/dev/null 2>&1
check "relabelling it development is not enough on its own" "f" \
  "$(q "$TARGET" 'SELECT app_data_is_servable()')"

# ── scrub ──────────────────────────────────────────────────────────────────────

say ""
say "── scrubbing"
psql -qAt -d "$TARGET" -c 'SELECT checks_end();' >/dev/null 2>&1
psql -qAt -d "$TARGET" -c "SELECT * FROM scrub_phi('$TARGET');" >/dev/null 2>&1 \
  || fail "scrub_phi refused"
FORCED_AFTER=$(q "$TARGET" "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relrowsecurity AND c.relforcerowsecurity")
check "and row-level security is still forced afterwards" "$SRC_FORCED" "$FORCED_AFTER"
psql -qAt -d "$TARGET" -c 'SELECT checks_begin();' >/dev/null 2>&1
check "the gate opens once the copy has been scrubbed" "t" \
  "$(q "$TARGET" 'SELECT app_data_is_servable()')"
check "and nothing of the original is left"            "0" \
  "$(q "$TARGET" "SELECT count(*) FROM phi_residue(ARRAY['${CANARY}'])")"

AFTER_VISIBLE=$(psql -qAt -d "$TARGET" 2>/dev/null <<SQL
SET ROLE dailycare_app;
SELECT set_config('app.user_id','a0000000-0000-0000-0000-00000000000a',false);
SELECT count(*) FROM care_days;
SQL
)
AFTER_VISIBLE=$(printf '%s\n' "$AFTER_VISIBLE" | tail -1)
check "and the application has a working database again" "$SRC_CAREDAYS" "$AFTER_VISIBLE"

# ── the row to record ──────────────────────────────────────────────────────────

say ""
say "── $PASSED passed, $FAILED failed, $ELAPSED minute(s) to restore"
if [ "$FAILED" = 0 ]; then
  say ""
  say "Record it:"
  say ""
  cat <<ROW
INSERT INTO restore_drills (performed_on, performed_by, environment, source_snapshot_at,
  restored_into, minutes_to_restore, rows_verified, copy_detected, scrub_confirmed, outcome)
VALUES (current_date, '<who>', 'development', now(),
        '$TARGET', $ELAPSED, $((SRC_RESIDENTS + SRC_CAREDAYS)), true, true, 'passed');
ROW
fi

[ "$FAILED" = 0 ]
