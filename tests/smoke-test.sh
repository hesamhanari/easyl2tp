#!/bin/bash
# Fake-data smoke test for ezl2tp.
# All values here are TEST-ONLY and fake. Do not use real credentials.
# Usage: bash tests/smoke-test.sh [path-to-ezl2tp]
# Exits non-zero if any check fails.
set -u

PANEL="${1:-./ezl2tp}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/sessions"
printf '"test-ali" l2tpd "test-pass-ali" *\n"test-sara" l2tpd "test-pass-sara" *\n' > "$TMP/chap-secrets"
printf '"test-ali" : PSK "test-pass-ali"\n: PSK "test-master-psk"\n' > "$TMP/ipsec.secrets"
printf '* * test-tun-pass\n' > "$TMP/l2tp-secrets"
printf 'test-ali 1000000 5000000\ntest-sara 200000 300000\n' > "$TMP/totals.db"
printf 'test-ali 10.99.0.10\n' > "$TMP/sessions/ppp0"
printf '2026-01-01 10:00:00 | CONNECT | L2TP(ppp0) | test-ali | Session started\n' > "$TMP/sessions.log"
printf '#!/bin/bash\necho "STUB l2tp-user $@"\n' > "$TMP/l2tp-user-stub"
chmod +x "$TMP/l2tp-user-stub"

export VPN_PANEL_CHAP="$TMP/chap-secrets"
export VPN_PANEL_IPSEC_SECRETS="$TMP/ipsec.secrets"
export VPN_PANEL_L2TP_SECRETS="$TMP/l2tp-secrets"
export VPN_PANEL_TOTALS_DB="$TMP/totals.db"
export VPN_PANEL_SESSIONS_LOG="$TMP/sessions.log"
export VPN_PANEL_SESSIONS_DIR="$TMP/sessions"
export VPN_PANEL_L2TP_USER="$TMP/l2tp-user-stub"

fail=0
check() { # check <name> <haystack> <needle>
  if printf '%s' "$2" | grep -qF "$3"; then
    echo "ok: $1"
  else
    echo "FAIL: $1 (missing: $3)"; fail=1
  fi
}

bash -n "$PANEL" || { echo "FAIL: syntax check"; exit 1; }
echo "ok: syntax check"

USERS="$(bash "$PANEL" users)"
check "users: ali online" "$USERS" "test-ali"
check "users: ali ONLINE" "$USERS" "ONLINE"
check "users: sara offline" "$USERS" "offline"

LIVE="$(bash "$PANEL" live)"
check "live: ppp0 session" "$LIVE" "ppp0"

CARD="$(bash "$PANEL" card test-ali)"
check "card: modem section" "$CARD" "plain L2TP"
check "card: IKEv2 section" "$CARD" "IKEv2"

if bash "$PANEL" card no-such-user >/dev/null 2>&1; then
  echo "FAIL: missing user should exit non-zero"; fail=1
else
  echo "ok: missing user exits non-zero"
fi

exit "$fail"
