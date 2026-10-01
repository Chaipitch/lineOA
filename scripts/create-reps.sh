#!/usr/bin/env bash
# Creates N test reps with LINE_Chat_User in an org that has LINE Connect, for multi-rep testing (QA org or scratch org).
#
#   ./scripts/create-reps.sh <org alias> <email> [count] [time zone ...]
#
#   <email>     inbox for the reps' welcome emails; plus-addressed per rep (you+linerep1@…, you+linerep2@…)
#   [count]     number of reps, 1-10 (default 3)
#   [time zone] IANA time zones handed out in turn (default Asia/Bangkok)
#
# Examples:
#   ./scripts/create-reps.sh chaipitch-devhub you@example.com 3
#   ./scripts/create-reps.sh chaipitch-devhub you@example.com 3 Asia/Bangkok Asia/Bangkok Asia/Tokyo
#
# Environment overrides:
#   SEND_WELCOME=0   don't send welcome emails (then set passwords from Setup → Users → Reset Password)
#
# Idempotent: reruns only add missing reps and permission set assignments. Usernames are line.rep<n>.<org id>@example.com.
# Uses Salesforce Platform seats first. Anonymous Apex only; this never deploys source (DEC-31).
set -euo pipefail

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

[ $# -ge 2 ] || usage
ALIAS="$1"
EMAIL="$2"
COUNT="${3:-3}"
shift $(($# < 3 ? $# : 3))
ZONES=("$@")
[ ${#ZONES[@]} -gt 0 ] || ZONES=("Asia/Bangkok")
SEND_WELCOME="${SEND_WELCOME:-1}"

# Every value below is pasted into Apex, so each is checked against a strict pattern first.
[[ "$EMAIL" =~ ^([A-Za-z0-9._%-]+)@([A-Za-z0-9.-]+\.[A-Za-z]{2,})$ ]] || { echo "Not a plain email address: $EMAIL" >&2; exit 1; }
EMAIL_LOCAL="${BASH_REMATCH[1]}"
EMAIL_DOMAIN="${BASH_REMATCH[2]}"
[[ "$COUNT" =~ ^([1-9]|10)$ ]] || { echo "Count must be 1-10: $COUNT" >&2; exit 1; }
ZONE_LIST=""
for z in "${ZONES[@]}"; do
    [[ "$z" =~ ^[A-Za-z_]+(/[A-Za-z0-9_+-]+){0,2}$ ]] || { echo "Not an IANA time zone: $z" >&2; exit 1; }
    ZONE_LIST+="${ZONE_LIST:+, }'$z'"
done
[ "$SEND_WELCOME" = "0" ] && WELCOME=false || WELCOME=true

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

sed -e "s|__COUNT__|$COUNT|" \
    -e "s|__TIME_ZONES__|$ZONE_LIST|" \
    -e "s|__EMAIL_LOCAL__|$EMAIL_LOCAL|" \
    -e "s|__EMAIL_DOMAIN__|$EMAIL_DOMAIN|" \
    -e "s|__SEND_WELCOME__|$WELCOME|" \
    "$ROOT/scripts/apex/create-reps.apex" > "$TMP/create-reps.apex"

printf '==> Creating %s rep(s) in %s\n' "$COUNT" "$ALIAS"
OUT="$(sf apex run --file "$TMP/create-reps.apex" --target-org "$ALIAS" 2>&1)" || { echo "$OUT" >&2; exit 1; }
if ! grep -q 'LINE_REP created' <<<"$OUT"; then
    echo "$OUT" >&2
    exit 1
fi
grep -o 'LINE_REP .*' <<<"$OUT" | sed 's/^LINE_REP /  /'
cat <<EOF

Next, per rep: open the welcome email and set a password, then register the rep's own LINE OA to them on the
LINE Admin page (05 Part D). Each rep needs a separate OA.
EOF
