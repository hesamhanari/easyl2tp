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

export EZL2TP_CHAP="$TMP/chap-secrets"
export EZL2TP_IPSEC_SECRETS="$TMP/ipsec.secrets"
export EZL2TP_L2TP_SECRETS="$TMP/l2tp-secrets"
export EZL2TP_TOTALS_DB="$TMP/totals.db"
export EZL2TP_SESSIONS_LOG="$TMP/sessions.log"
export EZL2TP_SESSIONS_DIR="$TMP/sessions"
export EZL2TP_L2TP_USER="$TMP/l2tp-user-stub"

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

# Run the panel the way install.sh installs it: a file named "ezl2tp"
# on PATH. This is what proves the vpn-panel -> ezl2tp rename works.
mkdir -p "$TMP/bin"
cp "$PANEL" "$TMP/bin/ezl2tp"
chmod +x "$TMP/bin/ezl2tp"
PATH="$TMP/bin:$PATH"
export PATH
if command -v vpn-panel >/dev/null 2>&1; then
  echo "FAIL: old command vpn-panel is still on PATH"; fail=1
else
  echo "ok: old command vpn-panel is gone"
fi
if grep -qiE 'vpn-panel|mehr23' "$PANEL"; then
  echo "FAIL: panel still mentions vpn-panel or mehr23"; fail=1
else
  echo "ok: panel has no vpn-panel / mehr23 mentions"
fi

STATUS="$(ezl2tp status)"
check "status: header" "$STATUS" "ezl2tp"
check "status: users line" "$STATUS" "Users:           2 total, 1 online"
check "status: traffic" "$STATUS" "Total traffic:"

USERS="$(ezl2tp users)"
check "users: ali online" "$USERS" "test-ali"
check "users: ali ONLINE" "$USERS" "ONLINE"
check "users: sara offline" "$USERS" "offline"

LIVE="$(ezl2tp live)"
check "live: ppp0 session" "$LIVE" "ppp0"

CARD="$(ezl2tp card test-ali)"
check "card: modem section" "$CARD" "plain L2TP"
check "card: IKEv2 section" "$CARD" "IKEv2"

check "card: own password" "$CARD" "test-pass-ali"
check "card: master PSK" "$CARD" "test-master-psk"
check "card: tunnel password" "$CARD" "test-tun-pass"
if printf '%s' "$CARD" | grep -qF "test-pass-sara"; then
  echo "FAIL: card leaks another user's password"; fail=1
else
  echo "ok: card does not contain other users' passwords"
fi
if printf '%s' "$USERS" | grep -qE 'test-pass|test-master|test-tun'; then
  echo "FAIL: users list shows a secret"; fail=1
else
  echo "ok: users list shows no secrets"
fi
check "users: ali totals" "$USERS" "5.72 MB"
check "stats delegates to l2tp-user" "$(ezl2tp stats)" "STUB l2tp-user stats"

if ezl2tp card no-such-user >/dev/null 2>&1; then
  echo "FAIL: missing user should exit non-zero"; fail=1
else
  echo "ok: missing user exits non-zero"
fi

exit "$fail"
