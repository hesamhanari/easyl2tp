#!/bin/bash
# Static checks for easyl2tp: shellcheck on every script (including the
# scripts install.sh writes out of heredocs) plus guards for the settings
# PR 1 removed. No network, nothing is installed.
# Usage: bash tests/lint.sh   (from anywhere)
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0

pass() { echo "ok: $1"; }
flunk() { echo "FAIL: $1"; fail=1; }
# must_pass <name> <command...>   must_fail <name> <command...>
must_pass() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$n"; else flunk "$n"; fi; }
must_fail() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then flunk "$n"; else pass "$n"; fi; }

command -v shellcheck >/dev/null 2>&1 || { echo "FAIL: shellcheck not installed"; exit 1; }

must_pass "shellcheck: repo scripts" shellcheck install.sh ezl2tp tests/*.sh
must_pass "install.sh syntax" bash -n install.sh

# Extract every quoted heredoc in install.sh that starts with a shebang
# (l2tp-user, l2tp-fw.sh, ip-up/down hooks, ...) and shellcheck it too.
python3 - "$TMP" <<'PY'
import re, sys
out = sys.argv[1]
t = open('install.sh').read()
for m in re.finditer(r"cat > (\S+) <<'(\w+)'\n(.*?)\n\2\n", t, re.S):
    if m.group(3).startswith('#!'):
        open(out + '/' + m.group(1).strip('/').replace('/', '_'), 'w').write(m.group(3) + '\n')
PY
n=0
for f in "$TMP"/*; do
  [ -f "$f" ] || continue
  n=$((n + 1))
  must_pass "shellcheck: embedded $(basename "$f")" shellcheck "$f"
done
if [ "$n" -ge 5 ]; then pass "found $n embedded scripts"; else flunk "expected >=5 embedded scripts, found $n"; fi

# Settings PR 1 removed must not come back.
must_fail "no aggressive-mode PSK flag" grep -q 'i_dont_care_about_security' install.sh
must_fail "xl2tpd must not set 'require authentication = no'" grep -q 'require authentication = no' install.sh
must_pass "xl2tpd requires PPP authentication" grep -q 'require authentication = yes' install.sh
must_fail "no global FORWARD policy change" grep -q 'iptables -P FORWARD' install.sh
# In POSIX regex \+ is a literal plus, not "one or more". It silently broke the
# IKEv2 user match (stats said offline), so it must stay [^ ]+.
must_fail "no \\+ in the IKEv2 ESTABLISHED regex" grep -qF '[^ ]\+' install.sh
must_pass "IKEv2 ESTABLISHED regex uses [^ ]+" grep -qF '[^ ]+\[' install.sh
must_fail "INPUT not open to all VPN clients" grep -qE '^[[:space:]]*add filter INPUT -i ppp\+ -j ACCEPT' install.sh

# Rename: the old name may appear only where install.sh removes it.
stray="$(grep -rniE 'vpn-panel|vpn_panel|mehr23' install.sh ezl2tp README.md SECURITY.md \
  | grep -vE 'rm -f /usr/local/bin/vpn-panel|renamed from vpn-panel to ezl2tp' || true)"
if [ -z "$stray" ]; then pass "no stray vpn-panel / mehr23 mentions"; else flunk "stray old-name mentions:"; echo "$stray"; fi

# No hardcoded server IPs (VPN subnet 10.99.*, public DNS, wildcards and the
# RFC 5737 documentation ranges are fine). Tests and docs too: output pasted
# from a test server must never end up in the repo.
ips="$(grep -nE '([0-9]{1,3}\.){3}[0-9]{1,3}' install.sh ezl2tp README.md tests/*.sh tests/*.md \
  | grep -vE '10\.99\.|1\.1\.1\.1|8\.8\.8\.8|0\.0\.0\.0|192\.0\.2\.|198\.51\.100\.|203\.0\.113\.' || true)"
if [ -z "$ips" ]; then pass "no hardcoded server IPs"; else flunk "possible hardcoded IPs:"; echo "$ips"; fi

# l2tp-user must reject bad input BEFORE touching any file or service.
awk '/^cat > \/usr\/local\/bin\/l2tp-user <<.USER_SCRIPT.$/{f=1;next} /^USER_SCRIPT$/{f=0} f' install.sh > "$TMP/l2tp-user"
for name in 'bad name' 'a"b' 'x;y' '../x' ''; do
  out="$(bash "$TMP/l2tp-user" add "$name" test-pass-123456 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'Invalid username'; then
    pass "l2tp-user rejects username '$name'"
  else
    flunk "l2tp-user did not reject username '$name' (rc=$rc)"
  fi
done
out="$(bash "$TMP/l2tp-user" add good-name 'bad pass' 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'Invalid password'; then pass "l2tp-user rejects a password with a space"; else flunk "l2tp-user accepted a bad password (rc=$rc)"; fi

exit "$fail"
