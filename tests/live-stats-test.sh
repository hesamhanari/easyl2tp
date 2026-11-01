#!/bin/bash
# Tests for live traffic and online status:
#   - the IKEv2 "ESTABLISHED" regression (the user was never captured, so stats
#     said offline and live bytes were lost)
#   - live counters on top of totals.db for stats, usage, and the ezl2tp panel
#   - online status comes from /run/vpn-sessions/* only, never "offline" while a
#     session file exists
#   - nothing is counted twice after a disconnect
#
# This runs the REAL l2tp-user and vpn-acct-update that install.sh writes out
# (extracted from their heredocs), with every file path rewritten to a temp
# directory, and ipsec / iptables replaced by stubs that print fixtures.
# ALL DATA HERE IS FAKE TEST DATA: users are test-user*, addresses are from the
# documentation ranges (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24) or the
# VPN pool this project defines (10.99.*). Never paste real server output here.
#
# Usage: bash tests/live-stats-test.sh [path-to-ezl2tp]
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PANEL="${1:-$ROOT/ezl2tp}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0

ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
# eq <name> <actual> <expected>
eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1"; echo "    expected: $3"; echo "    actual:   $2"; fi
}
# has <name> <haystack> <needle>
has() {
  if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1 (missing: $3)"; echo "    in: $2"; fi
}
hasnt() {
  if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1 (found: $3)"; else ok "$1"; fi
}

# ---- extract the real scripts and point every path at $TMP ----
extract() { # extract <install path> <heredoc tag>
  awk -v tgt="$1" -v tag="$2" '
    $0 == "cat > " tgt " <<'\''" tag "'\''" { f = 1; next }
    $0 == tag { f = 0 }
    f' "$ROOT/install.sh"
}
rewrite() {
  sed -e "s#/var/log/vpn-usage#$TMP/vpn-usage#g" \
    -e "s#/run/vpn-sessions#$TMP/sessions#g" \
    -e "s#/sys/class/net#$TMP/net#g" \
    -e "s#/etc/ppp/chap-secrets#$TMP/chap-secrets#g" \
    -e "s#/etc/ppp/pap-secrets#$TMP/pap-secrets#g" \
    -e "s#/etc/ipsec.conf#$TMP/ipsec.conf#g" \
    -e "s#/etc/ipsec.secrets#$TMP/ipsec.secrets#g" \
    -e "s#/etc/xl2tpd/l2tp-secrets#$TMP/l2tp-secrets#g"
}
LU="$TMP/l2tp-user"
ACCT="$TMP/vpn-acct-update"
extract /usr/local/bin/l2tp-user USER_SCRIPT | rewrite > "$LU"
extract /usr/local/sbin/vpn-acct-update ACCT | rewrite > "$ACCT"
chmod +x "$LU" "$ACCT"
if [ ! -s "$LU" ] || [ ! -s "$ACCT" ]; then
  echo "FAIL: could not extract l2tp-user / vpn-acct-update from install.sh"; exit 1
fi
# Safety: never let this test touch the real system.
for f in "$LU" "$ACCT"; do
  if grep -qE '/var/log/vpn-usage|/run/vpn-sessions|/sys/class/net|/etc/ppp/|/etc/ipsec|/etc/xl2tpd' "$f"; then
    echo "FAIL: path rewrite incomplete in $(basename "$f"); refusing to run"; exit 1
  fi
done

# ---- stubs for ipsec and iptables: print whatever the fixtures say ----
mkdir -p "$TMP/bin"
cat > "$TMP/bin/ipsec" <<'STUB'
#!/bin/bash
[ "${1:-}" = statusall ] && cat "$STATUSALL_FILE" 2>/dev/null
exit 0
STUB
cat > "$TMP/bin/iptables" <<'STUB'
#!/bin/bash
cat "$IPTABLES_FILE" 2>/dev/null
exit 0
STUB
chmod +x "$TMP/bin/ipsec" "$TMP/bin/iptables"
# The panel, installed the way install.sh does it: a file named ezl2tp on PATH.
cp "$PANEL" "$TMP/bin/ezl2tp"
chmod +x "$TMP/bin/ezl2tp"
PANEL="$TMP/bin/ezl2tp"
PATH="$TMP/bin:$PATH"
export PATH
# Server info that l2tp-user list reads (fake): ipsec.conf with the server id.
printf 'conn l2tp-psk\n  leftid=192.0.2.10\n' > "$TMP/ipsec.conf"
echo '* * test-tun-pass' > "$TMP/l2tp-secrets"
printf '"test-ali" : PSK "test-pass-ali"\n: PSK "test-master-psk"\n' > "$TMP/ipsec.secrets"
export STATUSALL_FILE="$TMP/statusall.txt"
export IPTABLES_FILE="$TMP/iptables.txt"

# The exact statusall lines from the live finding, with the three real
# addresses replaced by documentation-range ones (the format is what matters).
STATUSALL_EXACT='ikev2-psk[4]: ESTABLISHED 6 minutes ago, 192.0.2.10[198.51.100.20]...203.0.113.30[test-user1]
ikev2-psk{2}: AES_CBC_128/HMAC_SHA2_256_128, 149747 bytes_i (804 pkts, 1s ago), 339623 bytes_o (791 pkts, 1s ago)
ikev2-psk{2}: 0.0.0.0/0 === 10.99.1.10/32'

# The same session as a real `ipsec statusall` prints it (indented, with the
# lines around it).
STATUSALL_FULL='Status of IKE charon daemon (strongSwan 6.0.1, Linux 6.12.48+deb13-amd64, x86_64):
  uptime: 3 hours, since Nov 01 14:00:00 2026
Connections:
    ikev2-psk:  %any...%any  IKEv2, dpddelay=30s
    ikev2-psk:   child:  0.0.0.0/0 === dynamic TUNNEL, dpdaction=clear
Security Associations (1 up, 0 connecting):
 ikev2-psk[4]: ESTABLISHED 6 minutes ago, 192.0.2.10[198.51.100.20]...203.0.113.30[test-user1]
 ikev2-psk[4]: IKEv2 SPIs: 0123456789abcdef_i fedcba9876543210_r*, pre-shared key reauthentication in 2 hours
 ikev2-psk[4]: IKE proposal: AES_CBC_256/HMAC_SHA2_256_128/PRF_HMAC_SHA2_256/MODP_2048
 ikev2-psk{2}:  INSTALLED, TUNNEL, reqid 2, ESP in UDP SPIs: c1bd2da1_i c9bf8e5d_o
 ikev2-psk{2}:  AES_CBC_128/HMAC_SHA2_256_128, 149747 bytes_i (804 pkts, 1s ago), 339623 bytes_o (791 pkts, 1s ago), rekeying disabled
 ikev2-psk{2}:   0.0.0.0/0 === 10.99.1.10/32'

# ---- scenario helpers ----
fresh() {
  rm -rf "$TMP/sessions" "$TMP/net" "$TMP/vpn-usage" "$TMP/chap-secrets" "$STATUSALL_FILE" "$IPTABLES_FILE"
  mkdir -p "$TMP/sessions" "$TMP/net" "$TMP/vpn-usage"
  : > "$TMP/vpn-usage/totals.db"
  : > "$TMP/vpn-usage/sessions.log"
  : > "$TMP/chap-secrets"
  : > "$STATUSALL_FILE"
  : > "$IPTABLES_FILE"
}
add_user() { printf '"%s" l2tpd "test-pass-%s" *\n' "$1" "$1" >> "$TMP/chap-secrets"; }
set_totals() { printf '%s %s %s\n' "$1" "$2" "$3" >> "$TMP/vpn-usage/totals.db"; }
session() { printf '%s %s\n' "$2" "$3" > "$TMP/sessions/$1"; } # session <file> <user> <peer>
ppp_dev() { mkdir -p "$TMP/net/$1/statistics"; echo "$2" > "$TMP/net/$1/statistics/rx_bytes"; echo "$3" > "$TMP/net/$1/statistics/tx_bytes"; }
# iptables -nvxL FORWARD, as the up hook's IKEV2_UP_/IKEV2_DOWN_ rules print
ipt_rules() { # ipt_rules <user> <vip> <up_bytes> <down_bytes>
  {
    echo "Chain FORWARD (policy ACCEPT 0 packets, 0 bytes)"
    echo "    pkts      bytes target     prot opt in     out     source               destination"
    printf '%8s %10s ACCEPT     0    --  *      *       0.0.0.0/0            %-20s /* IKEV2_DOWN_%s */\n' 700 "$4" "$2" "$1"
    printf '%8s %10s ACCEPT     0    --  *      *       %-20s 0.0.0.0/0            /* IKEV2_UP_%s */\n' 800 "$3" "$2" "$1"
    printf '%8s %10s ACCEPT     0    --  *      *       10.99.0.0/24         0.0.0.0/0\n' 5 99999999
  } > "$IPTABLES_FILE"
}
# A leftover rule for the same VIP (an older user whose down hook never ran),
# listed BELOW the live one. Only the top-most rule is the live counter.
ipt_stale_rule() { # ipt_stale_rule <user> <vip> <up_bytes> <down_bytes>
  printf '%8s %10s ACCEPT     0    --  *      *       0.0.0.0/0            %-20s /* IKEV2_DOWN_%s */\n' 1 "$4" "$2" "$1" >> "$IPTABLES_FILE"
  printf '%8s %10s ACCEPT     0    --  *      *       %-20s 0.0.0.0/0            /* IKEV2_UP_%s */\n' 1 "$3" "$2" "$1" >> "$IPTABLES_FILE"
}
statusall() { printf '%s\n' "$1" > "$STATUSALL_FILE"; }
usage_of() { "$LU" usage 2>&1 | awk -v u="$1" '$1 == u'; }

# ================================================================
# 1. Regression: the exact statusall lines of the live finding.
#    Only statusall knows about this session (no session file, no iptables
#    rule, no ppp device) and stats must still say ONLINE with live bytes.
# ================================================================
fresh; add_user test-user1
statusall "$STATUSALL_EXACT"
eq "regression: usage row has the user, live bytes and the IKEv2 session" \
  "$(usage_of test-user1)" "test-user1 149747 339623 IKEv2(10.99.1.10)"
OUT="$("$LU" stats 2>&1)"
has "regression: stats says ONLINE: IKEv2(10.99.1.10)" "$OUT" "ONLINE: IKEv2(10.99.1.10)"
has "regression: stats shows the live upload (149747 B)" "$OUT" "146.24 KB"
has "regression: stats shows the live download (339623 B)" "$OUT" "331.66 KB"
hasnt "regression: stats does not say offline" "$OUT" "offline"
hasnt "regression: the session is not shown under a made-up name" "$OUT" "IKEv2_10.99.1.10"

# The same with the full, indented statusall output.
statusall "$STATUSALL_FULL"
eq "regression: full statusall output gives the same row" \
  "$(usage_of test-user1)" "test-user1 149747 339623 IKEv2(10.99.1.10)"

# The bug itself: with the old regex (\+ is a literal plus in POSIX regex) the
# user is never captured. The test above must notice if it ever comes back.
if grep -qF '[^ ]+\[' "$LU"; then
  content="$(cat "$LU")"
  printf '%s\n' "${content/'[^ ]+\['/'[^ ]\+\['}" > "$TMP/l2tp-user-oldregex"
  chmod +x "$TMP/l2tp-user-oldregex"
  statusall "$STATUSALL_EXACT"
  old="$("$TMP/l2tp-user-oldregex" usage 2>&1 | awk '$1 == "test-user1"')"
  if [ "$old" = "test-user1 149747 339623 IKEv2(10.99.1.10)" ]; then
    bad "mutation: the old [^ ]\\+ regex must make the regression check fail"
  else
    ok "mutation: the old [^ ]\\+ regex makes the regression check fail"
  fi
else
  bad "l2tp-user must contain the fixed [^ ]+ regex in the IKEv2 ESTABLISHED match"
fi

# ================================================================
# 2. Live counters on top of totals.db
# ================================================================
fresh; add_user test-user1; add_user test-user2; add_user test-user3
set_totals test-user1 1000000 2000000
set_totals test-user2 100 200
session ikev2_10.99.1.10 test-user1 10.99.1.10
statusall "$STATUSALL_FULL"
eq "IKEv2: totals.db + statusall bytes" "$(usage_of test-user1)" "test-user1 1149747 2339623 IKEv2(10.99.1.10)"

# iptables counters bigger than statusall (e.g. after a child SA rekey): use them
ipt_rules test-user1 10.99.1.10 5000000 9000000
eq "IKEv2: bigger iptables counters win" "$(usage_of test-user1)" "test-user1 6000000 11000000 IKEv2(10.99.1.10)"
# iptables smaller than statusall: statusall wins
ipt_rules test-user1 10.99.1.10 10 20
eq "IKEv2: bigger statusall bytes win" "$(usage_of test-user1)" "test-user1 1149747 2339623 IKEv2(10.99.1.10)"
# only iptables, no statusall bytes
statusall ""
ipt_rules test-user1 10.99.1.10 4000 8000
eq "IKEv2: iptables counters alone" "$(usage_of test-user1)" "test-user1 1004000 2008000 IKEv2(10.99.1.10)"
# a stale rule for the same VIP further down must not be added or preferred
ipt_rules test-user1 10.99.1.10 4000 8000
ipt_stale_rule test-user9 10.99.1.10 777777777 888888888
eq "IKEv2: the top-most rule is the live counter, a stale one below is ignored" \
  "$(usage_of test-user1)" "test-user1 1004000 2008000 IKEv2(10.99.1.10)"
ipt_rules test-user1 10.99.1.10 4000 8000
# the catch-all 10.99.0.0/24 rule is not a per-VIP counter and is ignored
hasnt "IKEv2: other FORWARD rules are not counted" "$(usage_of test-user1)" "99999999"

session ppp0 test-user2 10.99.0.10
ppp_dev ppp0 5000 7000
eq "L2TP: totals.db + ppp interface counters" "$(usage_of test-user2)" "test-user2 5100 7200 L2TP(ppp0)"
eq "offline user keeps a row with zero bytes" "$(usage_of test-user3)" "test-user3 0 0 -"

# one user on both protocols at once
session ppp1 test-user1 10.99.0.11
ppp_dev ppp1 300 400
eq "one user, IKEv2 + L2TP: bytes add up, both sessions listed" \
  "$(usage_of test-user1)" "test-user1 1004300 2008400 IKEv2(10.99.1.10),L2TP(ppp1)"
OUT="$("$LU" stats 2>&1)"
has "stats lists both sessions" "$OUT" "ONLINE: IKEv2(10.99.1.10), L2TP(ppp1)"

# ================================================================
# 3. Online status comes from /run/vpn-sessions/*
# ================================================================
fresh; add_user test-user1; add_user test-user2
set_totals test-user1 1000 2000
session ikev2_10.99.1.10 test-user1 10.99.1.10   # nothing else knows about it: no SA, no rule
session ppp7 test-user2 10.99.0.20                # no ppp device either
OUT="$("$LU" stats 2>&1)"
has "session file, nothing else: IKEv2 user is ONLINE" "$OUT" "ONLINE: IKEv2(10.99.1.10)"
has "session file, no device: L2TP user is ONLINE" "$OUT" "ONLINE: L2TP(ppp7)"
hasnt "stats never says offline while a session file exists" "$OUT" "offline"
eq "stale session: only the saved totals, no invented live bytes" "$(usage_of test-user1)" "test-user1 1000 2000 IKEv2(10.99.1.10)"
eq "stale session without a device: zero live bytes" "$(usage_of test-user2)" "test-user2 0 0 L2TP(ppp7)"
eq "list shows the same status as stats" "$("$LU" list 2>&1 | grep -c 'ONLINE')" "2"

# a ppp device or SA that no hook registered is still shown as online
fresh; add_user test-user1
ppp_dev ppp5 111 222
eq "unregistered ppp device is shown online under a placeholder name" \
  "$("$LU" usage | awk '$4 == "L2TP(ppp5)" { print $2, $3 }')" "111 222"

# `usage` and `stats` only read: no user is created, nothing is rewritten
before="$(cat "$TMP/chap-secrets")"
"$LU" usage > /dev/null 2>&1
"$LU" stats > /dev/null 2>&1
eq "usage and stats do not touch chap-secrets" "$(cat "$TMP/chap-secrets")" "$before"

# ================================================================
# 4. No double counting after a disconnect
# ================================================================
fresh; add_user test-user1
set_totals test-user1 1000 2000
session ikev2_10.99.1.10 test-user1 10.99.1.10
statusall "$STATUSALL_FULL"
ipt_rules test-user1 10.99.1.10 149747 339623
live="$(usage_of test-user1)"
eq "while connected: totals + live" "$live" "test-user1 150747 341623 IKEv2(10.99.1.10)"
# What ipsec-updown.sh does on down-client: remove the session file and the
# rules, then add the final bytes to totals.db.
rm -f "$TMP/sessions/ikev2_10.99.1.10"
statusall ""
: > "$IPTABLES_FILE"
"$ACCT" test-user1 149747 339623 "IKEv2(10.99.1.10)" DISCONNECT
eq "after disconnect: same bytes, now all from totals.db, offline" "$(usage_of test-user1)" "test-user1 150747 341623 -"

# L2TP: device and session file are gone after ip-down
fresh; add_user test-user2
set_totals test-user2 100 200
session ppp0 test-user2 10.99.0.10
ppp_dev ppp0 5000 7000
eq "L2TP while connected" "$(usage_of test-user2)" "test-user2 5100 7200 L2TP(ppp0)"
rm -f "$TMP/sessions/ppp0"
rm -rf "$TMP/net/ppp0"
"$ACCT" test-user2 5000 7000 "L2TP(ppp0)" DISCONNECT
eq "L2TP after disconnect: same bytes, once" "$(usage_of test-user2)" "test-user2 5100 7200 -"
eq "L2TP after disconnect: no ghost row" "$("$LU" usage)" "test-user2 5100 7200 -"

# A rule or SA left behind with no session file is not counted again.
fresh; add_user test-user1
set_totals test-user1 1000 2000
statusall ""
ipt_rules test-user1 10.99.1.10 149747 339623
eq "leftover iptables rule without a session is ignored" "$(usage_of test-user1)" "test-user1 1000 2000 -"
eq "leftover iptables rule creates no ghost row" "$("$LU" usage)" "test-user1 1000 2000 -"

# ================================================================
# 5. The panel (users, status) shows the same live numbers
# ================================================================
fresh; add_user test-user1; add_user test-user2; add_user test-user3
set_totals test-user1 1000000 2000000
set_totals test-user2 100 200
session ikev2_10.99.1.10 test-user1 10.99.1.10
session ppp0 test-user2 10.99.0.10
ppp_dev ppp0 5000 7000
statusall "$STATUSALL_FULL"
export EZL2TP_CHAP="$TMP/chap-secrets" EZL2TP_IPSEC_SECRETS="$TMP/ipsec.secrets" EZL2TP_L2TP_SECRETS="$TMP/l2tp-secrets"
export EZL2TP_TOTALS_DB="$TMP/vpn-usage/totals.db" EZL2TP_SESSIONS_LOG="$TMP/vpn-usage/sessions.log"
export EZL2TP_SESSIONS_DIR="$TMP/sessions" EZL2TP_L2TP_USER="$LU"
USERS="$("$PANEL" users 2>&1)"
row1="$(printf '%s\n' "$USERS" | grep '^test-user1 ')"
row2="$(printf '%s\n' "$USERS" | grep '^test-user2 ')"
row3="$(printf '%s\n' "$USERS" | grep '^test-user3 ')"
has "panel users: IKEv2 user is ONLINE" "$row1" "ONLINE"
has "panel users: IKEv2 user upload = totals + live (1.10 MB)" "$row1" "1.10 MB"
has "panel users: IKEv2 user download = totals + live (2.23 MB)" "$row1" "2.23 MB"
has "panel users: L2TP user is ONLINE" "$row2" "ONLINE"
has "panel users: L2TP user upload = totals + live (4.98 KB)" "$row2" "4.98 KB"
has "panel users: idle user is offline" "$row3" "offline"
STATUS="$("$PANEL" status 2>&1)"
has "panel status: users online counted from live sessions" "$STATUS" "Users:           3 total, 2 online"
has "panel status: total upload includes live bytes (1.10 MB)" "$STATUS" "upload 1.10 MB"
has "panel status: total download includes live bytes (2.24 MB)" "$STATUS" "download 2.24 MB"
hasnt "panel never prints passwords" "$USERS$STATUS" "test-pass"
# stats through the panel is the very same table
eq "panel stats == l2tp-user stats" "$("$PANEL" stats 2>&1)" "$("$LU" stats 2>&1)"

exit "$fail"
