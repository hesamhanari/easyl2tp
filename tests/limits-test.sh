#!/bin/bash
# Tests for per-user data limits (ezl2tp limit / l2tp-user limit):
#   - set and clear a limit (decimals, bad values, unknown users)
#   - limits live in their own file, so a usage reset never erases them
#   - usage = upload + download, totals.db + live counters, at-or-over blocks
#   - the 30-day period starts at the FIRST CONNECTION after the limit is set,
#     and the next connection after it ends resets the totals by itself
#   - a manual reset restarts the period from now
#   - block on exceed for BOTH protocols: new L2TP/ppp and IKEv2 sessions are
#     refused (the real ip-up and updown hooks), live ones are disconnected
#     (the 30-second enforcement run)
#   - a user with no limit is never blocked
#   - the panel shows limit, used, remaining, period end, BLOCKED / unlimited
#
# This runs the REAL l2tp-user, vpn-acct-update and the ip-up / IKEv2 updown
# hooks that install.sh writes out of their heredocs, with every path rewritten
# to a temp directory, and ipsec, iptables, ip, sysctl, curl and date replaced
# by stubs (date lets the test move the clock). A process called "pppd" stands
# in for a real pppd.
# ALL DATA HERE IS FAKE TEST DATA: users are test-user*, addresses are from the
# documentation ranges (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24) or the
# VPN pool this project defines (10.99.*). Never paste real server output here.
#
# Usage: bash tests/limits-test.sh [path-to-ezl2tp]
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PANEL="${1:-$ROOT/ezl2tp}"
TMP="$(mktemp -d)"
trap 'pkill -f "$TMP/pppd" 2>/dev/null; rm -rf "$TMP"' EXIT
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
LU="$TMP/l2tp-user"
ACCT="$TMP/vpn-acct-update"
IPUP="$TMP/ip-up-hook"
UPDOWN="$TMP/ipsec-updown"
rewrite() {
  sed -e "s#/var/log/vpn-usage#$TMP/vpn-usage#g" \
    -e "s#/var/lib/easyl2tp#$TMP/state#g" \
    -e "s#/run/vpn-sessions#$TMP/sessions#g" \
    -e "s#^RUN_DIR=\"/run\"#RUN_DIR=\"$TMP/run\"#" \
    -e "s#/sys/class/net#$TMP/net#g" \
    -e "s#/etc/ppp/chap-secrets#$TMP/chap-secrets#g" \
    -e "s#/etc/ppp/pap-secrets#$TMP/pap-secrets#g" \
    -e "s#/etc/ipsec.conf#$TMP/ipsec.conf#g" \
    -e "s#/etc/ipsec.secrets#$TMP/ipsec.secrets#g" \
    -e "s#/etc/xl2tpd/l2tp-secrets#$TMP/l2tp-secrets#g" \
    -e "s#/usr/local/bin/l2tp-user#$LU#g" \
    -e "s#/usr/local/sbin/vpn-acct-update#$ACCT#g" \
    -e "s#/proc/sys/net/ipv4/conf#$TMP/proc-conf#g"
}
extract /usr/local/bin/l2tp-user USER_SCRIPT | rewrite > "$LU"
extract /usr/local/sbin/vpn-acct-update ACCT | rewrite > "$ACCT"
extract /etc/ppp/ip-up.d/99-l2tp-rpfilter PPPFW | rewrite > "$IPUP"
extract /usr/local/sbin/ipsec-updown.sh UPDOWN | rewrite > "$UPDOWN"
chmod +x "$LU" "$ACCT" "$IPUP" "$UPDOWN"
for f in "$LU" "$ACCT" "$IPUP" "$UPDOWN"; do
  if [ ! -s "$f" ]; then echo "FAIL: could not extract $(basename "$f") from install.sh"; exit 1; fi
  # Safety: never let this test touch the real system.
  if grep -qE '/var/log/vpn-usage|/var/lib/easyl2tp|/run/|/sys/class/net|/etc/ppp/|/etc/ipsec|/etc/xl2tpd|/proc/sys|/usr/local/' "$f"; then
    echo "FAIL: path rewrite incomplete in $(basename "$f"); refusing to run"
    grep -nE '/var/log/vpn-usage|/var/lib/easyl2tp|/run/|/sys/class/net|/etc/ppp/|/etc/ipsec|/etc/xl2tpd|/proc/sys|/usr/local/' "$f"
    exit 1
  fi
done

# ---- stubs ----
REAL_DATE="$(command -v date)"
export REAL_DATE
mkdir -p "$TMP/bin"
# ipsec: log every call; statusall prints the fixture.
cat > "$TMP/bin/ipsec" <<'STUB'
#!/bin/bash
echo "$*" >> "$IPSEC_CALLS"
[ "${1:-}" = statusall ] && cat "$STATUSALL_FILE" 2>/dev/null
exit 0
STUB
# iptables: -nvxL prints the fixture, -D fails (so "while iptables -D" ends).
cat > "$TMP/bin/iptables" <<'STUB'
#!/bin/bash
case " $* " in
  *" -nvxL "*) cat "$IPTABLES_FILE" 2>/dev/null ;;
  *" -D "*) exit 1 ;;
esac
exit 0
STUB
# ip: always fails, so the hooks' "while ip rule del" loops end at once.
printf '#!/bin/bash\nexit 1\n' > "$TMP/bin/ip"
printf '#!/bin/bash\nexit 0\n' > "$TMP/bin/sysctl"
printf '#!/bin/bash\nexit 1\n' > "$TMP/bin/curl"
# date: FAKE_NOW moves the clock, except when the caller passes its own -d.
cat > "$TMP/bin/date" <<'STUB'
#!/bin/bash
for a in "$@"; do [ "$a" = "-d" ] && exec "$REAL_DATE" "$@"; done
[ -n "${FAKE_NOW:-}" ] && exec "$REAL_DATE" -d "@$FAKE_NOW" "$@"
exec "$REAL_DATE" "$@"
STUB
chmod +x "$TMP/bin/"*
# A process whose name is "pppd" (the limit check only signals real pppd processes).
cp "$(command -v sleep)" "$TMP/pppd"
cp "$PANEL" "$TMP/bin/ezl2tp"
chmod +x "$TMP/bin/ezl2tp"
PANEL="$TMP/bin/ezl2tp"
PATH="$TMP/bin:$PATH"
export PATH
export STATUSALL_FILE="$TMP/statusall.txt"
export IPTABLES_FILE="$TMP/iptables.txt"
export IPSEC_CALLS="$TMP/ipsec-calls"
export EZL2TP_CHAP="$TMP/chap-secrets" EZL2TP_IPSEC_SECRETS="$TMP/ipsec.secrets" EZL2TP_L2TP_SECRETS="$TMP/l2tp-secrets"
export EZL2TP_TOTALS_DB="$TMP/vpn-usage/totals.db" EZL2TP_SESSIONS_LOG="$TMP/vpn-usage/sessions.log"
export EZL2TP_SESSIONS_DIR="$TMP/sessions" EZL2TP_L2TP_USER="$LU"
printf 'conn l2tp-psk\n  leftid=192.0.2.10\n' > "$TMP/ipsec.conf"
echo '* * test-tun-pass' > "$TMP/l2tp-secrets"
printf '"test-user1" : PSK "test-pass-test-user1"\n: PSK "test-master-psk"\n' > "$TMP/ipsec.secrets"

# ---- clock and units ----
GB=1073741824
DAY=86400
PERIOD=$((30 * DAY))
T0=1800000000 # 2027-01-15 08:00:00 UTC
export FAKE_NOW="$T0"

# ---- scenario helpers ----
fresh() {
  pkill -f "$TMP/pppd" 2>/dev/null
  rm -rf "$TMP/sessions" "$TMP/net" "$TMP/vpn-usage" "$TMP/state" "$TMP/run" "$TMP/chap-secrets" \
    "$STATUSALL_FILE" "$IPTABLES_FILE" "$IPSEC_CALLS"
  mkdir -p "$TMP/sessions" "$TMP/net" "$TMP/vpn-usage" "$TMP/state" "$TMP/run"
  : > "$TMP/vpn-usage/totals.db"
  : > "$TMP/vpn-usage/sessions.log"
  : > "$TMP/chap-secrets"
  : > "$TMP/pap-secrets"
  : > "$STATUSALL_FILE"
  : > "$IPTABLES_FILE"
  : > "$IPSEC_CALLS"
  : > "$TMP/state/limits.db"
  FAKE_NOW="$T0"
}
add_user() { printf '"%s" l2tpd "test-pass-%s" *\n' "$1" "$1" >> "$TMP/chap-secrets"; }
set_totals() { printf '%s %s %s\n' "$1" "$2" "$3" >> "$TMP/vpn-usage/totals.db"; }
totals_row() { awk -v u="$1" '$1 == u' "$TMP/vpn-usage/totals.db"; }
put_limit() { printf '%s %s %s\n' "$1" "$2" "$3" >> "$TMP/state/limits.db"; } # put_limit <user> <bytes> <start>
limit_rec() { awk -v u="$1" '$1 == u' "$TMP/state/limits.db"; }
session() { printf '%s %s\n' "$2" "$3" > "$TMP/sessions/$1"; } # session <file> <user> <peer>
ppp_dev() { mkdir -p "$TMP/net/$1/statistics"; echo "$2" > "$TMP/net/$1/statistics/rx_bytes"; echo "$3" > "$TMP/net/$1/statistics/tx_bytes"; }
# A process named pppd plus its pid file, like pppd writes /run/pppN.pid. Sets LAST_PID.
LAST_PID=""
fake_pppd() { # fake_pppd <pppN>
  "$TMP/pppd" 300 > /dev/null 2>&1 &
  LAST_PID=$!
  printf '%s\n%s\n' "$LAST_PID" "$1" > "$TMP/run/$1.pid"
}
alive() { # a killed child stays a zombie until reaped, so look at the state
  local st
  st="$(awk '{ print $3 }' "/proc/$1/stat" 2>/dev/null)"
  [ -n "$st" ] && [ "$st" != "Z" ]
}
wait_dead() { for _ in $(seq 1 40); do alive "$1" || return 0; sleep 0.1; done; return 1; }
wait_call() { for _ in $(seq 1 60); do grep -qF -- "$1" "$IPSEC_CALLS" 2>/dev/null && return 0; sleep 0.1; done; return 1; }
statusall() { printf '%s\n' "$1" > "$STATUSALL_FILE"; }
sa_line() { # sa_line <sa id> <child id> <user> <vip> <bytes_i> <bytes_o> <peer>
  printf ' ikev2-psk[%s]: ESTABLISHED 6 minutes ago, 192.0.2.10[198.51.100.20]...%s[%s]\n' "$1" "$7" "$3"
  printf ' ikev2-psk{%s}:  AES_CBC_128/HMAC_SHA2_256_128, %s bytes_i (8 pkts, 1s ago), %s bytes_o (7 pkts, 1s ago), rekeying disabled\n' "$2" "$5" "$6"
  printf ' ikev2-psk{%s}:   0.0.0.0/0 === %s/32\n' "$2" "$4"
}
limrow() { "$LU" limits 2>&1 | awk -v u="$1" '$1 == u'; }
field() { awk -v n="$2" '{ print $n }' <<< "$1"; } # field <row> <n>
lu() { "$LU" "$@" 2>&1; }
# gate <user>: prints the exit status (0 = let in, 3 = refuse)
gate_rc() { "$LU" gate "$1" "${2:-TEST}" > /dev/null 2>&1; echo $?; }

# ================================================================
# 1. Set and clear a limit
# ================================================================
fresh; add_user test-user1; add_user test-user2
set_totals test-user1 1000 2000
before_totals="$(cat "$TMP/vpn-usage/totals.db")"
OUT="$(lu limit test-user1 50)"; rc=$?
eq "limit 50: exits 0" "$rc" "0"
eq "limit 50: stored in bytes, period not started (0)" "$(limit_rec test-user1)" "test-user1 53687091200 0"
has "limit 50: says what was set" "$OUT" "50.00 GB per 30-day period"
has "limit 50: says the period starts at the first connection" "$OUT" "first connection"
OUT="$(lu limit test-user1 12.5)"
eq "limit 12.5: decimals are allowed" "$(limit_rec test-user1)" "test-user1 13421772800 0"
eq "limit 12.5: replaces the old limit, no second line" "$(grep -c '^test-user1 ' "$TMP/state/limits.db")" "1"
has "limit 12.5: says the new limit" "$OUT" "12.50 GB per 30-day period"
lu limit test-user2 1 > /dev/null
eq "a second user gets their own line" "$(wc -l < "$TMP/state/limits.db" | tr -d ' ')" "2"
eq "setting limits does not touch totals.db" "$(cat "$TMP/vpn-usage/totals.db")" "$before_totals"
OUT="$(lu limit test-user1 clear)"
eq "clear: the record is gone" "$(limit_rec test-user1)" ""
has "clear: says unlimited" "$OUT" "unlimited"
eq "clear: other users keep their limit" "$(limit_rec test-user2)" "test-user2 1073741824 0"
has "clear again: says there was no limit" "$(lu limit test-user1 clear)" "had no limit"
eq "clear does not touch totals.db" "$(cat "$TMP/vpn-usage/totals.db")" "$before_totals"

keep="$(cat "$TMP/state/limits.db")"
for v in abc 0 0.0 -5 1e3 1.2.3 ".5" "5." "5 GB" "" 99999999; do
  OUT="$(lu limit test-user1 "$v")"; rc=$?
  if [ "$rc" -ne 0 ]; then ok "limit '$v' is rejected"; else bad "limit '$v' was accepted"; fi
done
eq "rejected values change nothing" "$(cat "$TMP/state/limits.db")" "$keep"
OUT="$(lu limit test-nobody 5)"; rc=$?
if [ "$rc" -ne 0 ]; then ok "limit for an unknown user is rejected"; else bad "limit for an unknown user was accepted"; fi
has "unknown user: says not found" "$OUT" "not found"
OUT="$(lu limit 'a b' 5)"; rc=$?
if [ "$rc" -ne 0 ]; then ok "limit for a bad user name is rejected"; else bad "limit for a bad user name was accepted"; fi
eq "unknown or bad users add no record" "$(cat "$TMP/state/limits.db")" "$keep"
has "limit without a value prints usage" "$(lu limit test-user1)" "Usage: l2tp-user limit"

# `del` forgets the user's limit (a new user with the same name starts unlimited)
lu del test-user2 > /dev/null
eq "del removes the user's limit" "$(limit_rec test-user2)" ""

# ================================================================
# 2. Usage = upload + download, totals.db + live counters, at or over blocks
# ================================================================
fresh; add_user test-user1
set_totals test-user1 1000 2000
session ppp0 test-user1 10.99.0.10
ppp_dev ppp0 300 400
put_limit test-user1 3700 "$T0"
ROW="$(limrow test-user1)"
eq "used = upload + download, totals.db + live (1000+2000+300+400)" "$(field "$ROW" 3)" "3700"
eq "exactly AT the limit counts as over: BLOCKED" "$(field "$ROW" 6)" "BLOCKED"
eq "row lists the live session" "$(field "$ROW" 7)" "L2TP(ppp0)"
fresh; add_user test-user1
set_totals test-user1 1000 2000
session ppp0 test-user1 10.99.0.10
ppp_dev ppp0 300 400
put_limit test-user1 3701 "$T0"
eq "one byte under the limit: ok" "$(field "$(limrow test-user1)" 6)" "ok"
FAKE_NOW=$((T0 + DAY))
eq "gate: one byte under the limit is let in" "$(gate_rc test-user1)" "0"
fresh; add_user test-user1
set_totals test-user1 1000 2000
session ppp0 test-user1 10.99.0.10
ppp_dev ppp0 300 400
put_limit test-user1 3700 "$T0"
FAKE_NOW=$((T0 + DAY))
eq "gate: used EXACTLY at the limit is refused (at or over)" "$(gate_rc test-user1)" "3"

# No double count after a disconnect: the live bytes move into totals.db.
fresh; add_user test-user1
set_totals test-user1 1000 2000
session ppp0 test-user1 10.99.0.10
ppp_dev ppp0 300 400
put_limit test-user1 100000 "$T0"
eq "while connected: used" "$(field "$(limrow test-user1)" 3)" "3700"
rm -f "$TMP/sessions/ppp0"; rm -rf "$TMP/net/ppp0"
"$ACCT" test-user1 300 400 "L2TP(ppp0)" DISCONNECT
eq "after disconnect: the same used, counted once" "$(field "$(limrow test-user1)" 3)" "3700"
eq "after disconnect: user is offline" "$(field "$(limrow test-user1)" 7)" "-"

# ================================================================
# 3. Period: starts at the first connection, ends after 30 days, auto-reset
# ================================================================
fresh; add_user test-user1; add_user test-user2
set_totals test-user1 5000 5000 # old usage from before the limit
lu limit test-user1 1 > /dev/null
ROW="$(limrow test-user1)"
eq "after set: state is pending" "$(field "$ROW" 6)" "pending"
eq "after set: no period start or end yet" "$(field "$ROW" 4)/$(field "$ROW" 5)" "0/0"
FAKE_NOW=$((T0 + 3 * DAY)) # the user first connects 3 days later, not when the limit was set
eq "first connection after the limit: let in" "$(gate_rc test-user1)" "0"
eq "the period starts AT that connection, not when the limit was set" "$(limit_rec test-user1)" "test-user1 $GB $((T0 + 3 * DAY))"
eq "the period start is the connection time, not a calendar month start" "$(date -u -d "@$((T0 + 3 * DAY))" +%d)" "18"
eq "a new period begins with zero totals" "$(totals_row test-user1)" ""
has "the new period is logged" "$(cat "$TMP/vpn-usage/sessions.log")" "New data-limit period started"
ROW="$(limrow test-user1)"
eq "state is ok, period ends 30 days after the start" "$(field "$ROW" 6) $(field "$ROW" 5)" "ok $((T0 + 3 * DAY + PERIOD))"
S1=$((T0 + 3 * DAY))
FAKE_NOW=$((S1 + DAY))
eq "a second connection inside the period does not restart it" "$(gate_rc test-user1)" "0"
eq "... the period start is unchanged" "$(limit_rec test-user1)" "test-user1 $GB $S1"

# a second user has their own period
lu limit test-user2 2 > /dev/null
FAKE_NOW=$((S1 + 10 * DAY))
gate_rc test-user2 > /dev/null
eq "periods are per user: user 2 has their own start" "$(limit_rec test-user2)" "test-user2 $((2 * GB)) $((S1 + 10 * DAY))"

# fill user 1's quota
set_totals test-user1 $((GB - 10)) 20
FAKE_NOW=$((S1 + 11 * DAY))
eq "over the limit inside the period: refused (exit 3)" "$(gate_rc test-user1 "L2TP(ppp9)")" "3"
eq "a refused user is shown as BLOCKED" "$(field "$(limrow test-user1)" 6)" "BLOCKED"
has "the refusal is logged" "$(cat "$TMP/vpn-usage/sessions.log")" "Refused: data limit reached"
eq "a refusal does not reset anything" "$(limit_rec test-user1)" "test-user1 $GB $S1"
FAKE_NOW=$((S1 + PERIOD - 1))
eq "one second before the period ends: still refused" "$(gate_rc test-user1)" "3"
eq "... totals are untouched" "$(totals_row test-user1)" "test-user1 $((GB - 10)) 20"
eq "one second before the end: expired is not shown yet" "$(field "$(limrow test-user1)" 6)" "BLOCKED"
FAKE_NOW=$((S1 + PERIOD))
eq "at the end of the period the state is expired (not blocked)" "$(field "$(limrow test-user1)" 6)" "expired"
eq "the next connection is let in" "$(gate_rc test-user1)" "0"
eq "... totals reset to zero by themselves" "$(totals_row test-user1)" ""
eq "... a new period starts now, the limit is the same" "$(limit_rec test-user1)" "test-user1 $GB $((S1 + PERIOD))"
eq "... and the user is ok again" "$(field "$(limrow test-user1)" 6)" "ok"
eq "user 2's period is not touched by user 1's reset" "$(limit_rec test-user2)" "test-user2 $((2 * GB)) $((S1 + 10 * DAY))"

# the gate never asks charon for its status (that would wait for the SA being set up)
fresh; add_user test-user1
put_limit test-user1 $GB "$T0"
: > "$IPSEC_CALLS"
gate_rc test-user1 > /dev/null
eq "gate does not call ipsec statusall" "$(cat "$IPSEC_CALLS")" ""
"$LU" usage > /dev/null 2>&1
has "(control: usage does call ipsec statusall)" "$(cat "$IPSEC_CALLS")" "statusall"

# ================================================================
# 4. Manual reset restarts the period and keeps the limit
# ================================================================
fresh; add_user test-user1; add_user test-user2; add_user test-user3
put_limit test-user1 1000 "$T0"
put_limit test-user2 2000 "$T0"
set_totals test-user1 900 900
set_totals test-user2 5 5
set_totals test-user3 7 7
FAKE_NOW=$((T0 + 10 * DAY))
eq "before reset: user 1 is BLOCKED" "$(field "$(limrow test-user1)" 6)" "BLOCKED"
OUT="$(lu reset test-user1)"
eq "reset <user>: totals are zero" "$(totals_row test-user1)" ""
eq "reset <user>: the limit is still there" "$(field "$(limit_rec test-user1)" 2)" "1000"
eq "reset <user>: the period restarts from now" "$(field "$(limit_rec test-user1)" 3)" "$FAKE_NOW"
has "reset <user>: says so" "$OUT" "period restarted from now"
eq "reset <user>: a blocked user can connect again" "$(gate_rc test-user1)" "0"
eq "reset <user>: other users keep their totals" "$(totals_row test-user2)" "test-user2 5 5"
eq "reset <user>: other users' periods are not restarted" "$(limit_rec test-user2)" "test-user2 2000 $T0"
FAKE_NOW=$((T0 + 12 * DAY))
lu reset > /dev/null
eq "reset all: totals.db is empty" "$(cat "$TMP/vpn-usage/totals.db")" ""
eq "reset all: both limits are still there" "$(awk '{ print $1 ":" $2 }' "$TMP/state/limits.db" | tr '\n' ' ')" "test-user1:1000 test-user2:2000 "
eq "reset all: both periods restart from now" "$(awk '{ print $3 }' "$TMP/state/limits.db" | sort -u)" "$FAKE_NOW"
# a user without a limit: reset creates no limit
lu reset test-user3 > /dev/null
eq "reset of an unlimited user creates no limit" "$(limit_rec test-user3)" ""
# pending users: reset starts the period now (this is how an always-on modem is started)
fresh; add_user test-user1
lu limit test-user1 5 > /dev/null
FAKE_NOW=$((T0 + DAY))
lu reset test-user1 > /dev/null
eq "reset on a pending user starts the period now" "$(limit_rec test-user1)" "test-user1 $((5 * GB)) $FAKE_NOW"
# the installer must not truncate the limits on a re-install
if grep -qE '^[[:space:]]*(:|echo[^>]*|printf[^>]*)?[[:space:]]*>[[:space:]]*/var/lib/easyl2tp/limits.db' "$ROOT/install.sh"; then
  bad "install.sh truncates limits.db"
else
  ok "install.sh does not truncate limits.db (touch only)"
fi

# ================================================================
# 5. Block on exceed, new connections: L2TP/ppp (the real ip-up hook)
# ================================================================
fresh; add_user test-user1; add_user test-user2; add_user test-user3
put_limit test-user1 1000 "$T0"; set_totals test-user1 600 600     # over
put_limit test-user2 1000000 "$T0"; set_totals test-user2 1 1      # under
set_totals test-user3 999999999999 999999999999                    # no limit at all
FAKE_NOW=$((T0 + DAY))
ipup() { # ipup <user>: run the hook for a new session ppp0; leaves HOOK_RC set
  PEERNAME="$1" PPPD_PID="$LAST_PID" "$IPUP" ppp0 /dev/pts/0 115200 10.99.0.1 10.99.0.10 > /dev/null 2>&1
  HOOK_RC=$?
}
fake_pppd ppp0
ipup test-user1
eq "L2TP over the limit: the hook fails" "$HOOK_RC" "1"
if wait_dead "$LAST_PID"; then ok "L2TP over the limit: its pppd was stopped"; else bad "L2TP over the limit: pppd still running"; fi
eq "L2TP over the limit: no session is registered" "$(ls "$TMP/sessions")" ""
has "L2TP over the limit: the refusal is logged for ppp0" "$(cat "$TMP/vpn-usage/sessions.log")" "L2TP(ppp0)"
has "L2TP over the limit: ... with the reason" "$(cat "$TMP/vpn-usage/sessions.log")" "Refused: data limit reached"

fake_pppd ppp0
ipup test-user2
eq "L2TP under the limit: the hook succeeds" "$HOOK_RC" "0"
sleep 0.3
if alive "$LAST_PID"; then ok "L2TP under the limit: pppd keeps running"; else bad "L2TP under the limit: pppd was stopped"; fi
eq "L2TP under the limit: the session is registered" "$(cat "$TMP/sessions/ppp0")" "test-user2 10.99.0.10"
rm -f "$TMP/sessions/ppp0"

ipup test-user3
eq "L2TP, no limit set: the hook succeeds" "$HOOK_RC" "0"
sleep 0.3
if alive "$LAST_PID"; then ok "L2TP, no limit set: never blocked, however much was used"; else bad "L2TP, no limit set: pppd was stopped"; fi
eq "L2TP, no limit set: the session is registered" "$(cat "$TMP/sessions/ppp0")" "test-user3 10.99.0.10"
rm -f "$TMP/sessions/ppp0"

# a broken limit check must not lock everybody out: fail open
sed "s#$LU#$TMP/no-such-l2tp-user#g" "$IPUP" > "$TMP/ip-up-broken"; chmod +x "$TMP/ip-up-broken"
PEERNAME=test-user1 PPPD_PID="$LAST_PID" "$TMP/ip-up-broken" ppp0 /dev/pts/0 115200 10.99.0.1 10.99.0.10 > /dev/null 2>&1
eq "L2TP: if l2tp-user is missing the session is let in (fail open)" "$?" "0"
rm -f "$TMP/sessions/ppp0"

# ================================================================
# 6. Block on exceed, new connections: IKEv2 (the real updown hook)
# ================================================================
fresh; add_user test-user1; add_user test-user2; add_user test-user3
put_limit test-user1 1000 "$T0"; set_totals test-user1 600 600
put_limit test-user2 1000000 "$T0"; set_totals test-user2 1 1
set_totals test-user3 999999999999 999999999999
FAKE_NOW=$((T0 + DAY))
updown_up() { # updown_up <user> <vip> [unique id]
  PLUTO_VERB=up-client PLUTO_PEER_ID="$1" PLUTO_PEER_SOURCEIP="$2" PLUTO_CONNECTION=ikev2-psk \
    PLUTO_UNIQUEID="${3-}" "$UPDOWN" > /dev/null 2>&1
  HOOK_RC=$?
}
updown_up test-user1 10.99.1.10 7
eq "IKEv2 over the limit: the hook itself returns 0 quickly" "$HOOK_RC" "0"
eq "IKEv2 over the limit: no session is registered" "$(ls "$TMP/sessions")" ""
if wait_call "down ikev2-psk[7]"; then ok "IKEv2 over the limit: exactly that IKE SA is taken down (ipsec down ikev2-psk[7])"; else bad "IKEv2 over the limit: no ipsec down for SA 7"; fi
eq "IKEv2 over the limit: only that one call, no statusall from inside the hook" "$(cat "$IPSEC_CALLS")" "down ikev2-psk[7]"
has "IKEv2 over the limit: the refusal is logged" "$(cat "$TMP/vpn-usage/sessions.log")" "IKEv2(10.99.1.10)"

: > "$IPSEC_CALLS"
updown_up test-user2 10.99.1.11 8
eq "IKEv2 under the limit: the session is registered" "$(cat "$TMP/sessions/ikev2_10.99.1.11")" "test-user2 10.99.1.11"
sleep 1.5
eq "IKEv2 under the limit: nothing is taken down" "$(cat "$IPSEC_CALLS")" ""
rm -f "$TMP/sessions/ikev2_10.99.1.11"

updown_up test-user3 10.99.1.12 9
eq "IKEv2, no limit set: the session is registered" "$(cat "$TMP/sessions/ikev2_10.99.1.12")" "test-user3 10.99.1.12"
sleep 1.5
eq "IKEv2, no limit set: never taken down, however much was used" "$(cat "$IPSEC_CALLS")" ""
rm -f "$TMP/sessions/ikev2_10.99.1.12"

# No unique id: never "ipsec down" the whole connection. Register the session so
# the 30-second check can end it.
updown_up test-user1 10.99.1.13
eq "IKEv2 over the limit, no unique id: registered for the 30-second check" "$(cat "$TMP/sessions/ikev2_10.99.1.13")" "test-user1 10.99.1.13"
sleep 1.5
eq "IKEv2 over the limit, no unique id: no ipsec down of the whole connection" "$(cat "$IPSEC_CALLS")" ""
rm -f "$TMP/sessions/ikev2_10.99.1.13"

# ================================================================
# 7. Block on exceed, live sessions: the enforcement run
# ================================================================
fresh
for n in 1 2 3 4 5 6; do add_user "test-user$n"; done
put_limit test-user1 5000 "$T0";    set_totals test-user1 100 100          # over, online on both protocols
put_limit test-user2 1000000 "$T0"; set_totals test-user2 1 1              # under, online
set_totals test-user3 999999999999 999999999999                            # no limit, online
put_limit test-user4 10 0;          set_totals test-user4 99999 99999      # pending (period not started), online
put_limit test-user5 10 "$T0";      set_totals test-user5 99999 99999      # over but offline
put_limit test-user6 5000 "$T0";    set_totals test-user6 100 100          # over, but the pid file names a stranger
FAKE_NOW=$((T0 + DAY))
fake_pppd ppp0; P1=$LAST_PID; session ppp0 test-user1 10.99.0.10; ppp_dev ppp0 3000 3000
fake_pppd ppp1; P2=$LAST_PID; session ppp1 test-user2 10.99.0.11; ppp_dev ppp1 10 10
fake_pppd ppp2; P3=$LAST_PID; session ppp2 test-user3 10.99.0.12; ppp_dev ppp2 10 10
fake_pppd ppp3; P4=$LAST_PID; session ppp3 test-user4 10.99.0.13; ppp_dev ppp3 10 10
# user 6: a pid file that names a process that is NOT pppd
sleep 300 & STRANGER=$!
printf '%s\nppp5\n' "$STRANGER" > "$TMP/run/ppp5.pid"; session ppp5 test-user6 10.99.0.15; ppp_dev ppp5 3000 3000
{
  sa_line 4 2 test-user1 10.99.1.10 1000 2000 203.0.113.30
  sa_line 5 3 test-user2 10.99.1.11 10 10 203.0.113.31
} > "$TMP/sa.txt"
statusall "$(cat "$TMP/sa.txt")"
session ikev2_10.99.1.10 test-user1 10.99.1.10
session ikev2_10.99.1.11 test-user2 10.99.1.11
eq "setup: user 1 is over (totals + L2TP + IKEv2)" "$(field "$(limrow test-user1)" 6)" "BLOCKED"
eq "setup: user 2 is ok" "$(field "$(limrow test-user2)" 6)" "ok"
eq "setup: user 4 is pending" "$(field "$(limrow test-user4)" 6)" "pending"
: > "$IPSEC_CALLS"
lu enforce > /dev/null
if wait_dead "$P1"; then ok "enforce: the over-limit user's L2TP session (pppd) is disconnected"; else bad "enforce: user 1's pppd is still running"; fi
has "enforce: the over-limit user's IKEv2 SA is taken down" "$(cat "$IPSEC_CALLS")" "down ikev2-psk[4]"
eq "enforce: exactly one ipsec down, only for that SA" "$(grep -c '^down ' "$IPSEC_CALLS")" "1"
hasnt "enforce: the under-limit user's IKEv2 SA is left alone" "$(cat "$IPSEC_CALLS")" "ikev2-psk[5]"
sleep 0.3
if alive "$P2"; then ok "enforce: an under-limit user stays connected"; else bad "enforce: an under-limit user was disconnected"; fi
if alive "$P3"; then ok "enforce: a user with NO limit stays connected"; else bad "enforce: a user without a limit was disconnected"; fi
if alive "$P4"; then ok "enforce: a pending period (not started) is not enforced"; else bad "enforce: a pending user was disconnected"; fi
if alive "$STRANGER"; then ok "enforce: a pid file naming a process that is not pppd is never signalled"; else bad "enforce: killed a process that is not pppd"; fi
has "enforce: the disconnect is logged" "$(cat "$TMP/vpn-usage/sessions.log")" "Disconnected: data limit reached"
# a second run (hooks have not cleaned up yet in this test) does not hurt anyone else
lu enforce > /dev/null
if alive "$P2" && alive "$P3"; then ok "enforce: running it again still leaves everyone else alone"; else bad "enforce: second run hit another user"; fi
kill "$STRANGER" 2>/dev/null

# nobody has a limit: enforce is a no-op and does not even ask charon
fresh; add_user test-user1
set_totals test-user1 999999999999 999999999999
fake_pppd ppp0; session ppp0 test-user1 10.99.0.10; ppp_dev ppp0 1 1
: > "$IPSEC_CALLS"
lu enforce > /dev/null
sleep 0.3
if alive "$LAST_PID"; then ok "no limits at all: enforce disconnects nobody"; else bad "no limits at all: enforce disconnected someone"; fi
eq "no limits at all: enforce makes no ipsec call" "$(cat "$IPSEC_CALLS")" ""

# a user who is under the limit is never touched, however many sessions they have
fresh; add_user test-user1
put_limit test-user1 1000000 "$T0"; set_totals test-user1 10 10
fake_pppd ppp0; session ppp0 test-user1 10.99.0.10; ppp_dev ppp0 1 1
statusall "$(sa_line 4 2 test-user1 10.99.1.10 5 5 203.0.113.30)"
session ikev2_10.99.1.10 test-user1 10.99.1.10
: > "$IPSEC_CALLS"
lu enforce > /dev/null
sleep 0.3
if alive "$LAST_PID"; then ok "under the limit, two sessions: both stay"; else bad "under the limit: a session was stopped"; fi
eq "under the limit, two sessions: no ipsec down" "$(grep -c '^down ' "$IPSEC_CALLS")" "0"

# the limit is lowered below what was used: the live session ends at the next run
fresh; add_user test-user1
put_limit test-user1 1000000000 "$T0"; set_totals test-user1 5000 5000
fake_pppd ppp0; session ppp0 test-user1 10.99.0.10; ppp_dev ppp0 1 1
lu enforce > /dev/null; sleep 0.3
if alive "$LAST_PID"; then ok "before lowering the limit: still connected"; else bad "disconnected too early"; fi
OUT="$(lu limit test-user1 0.000001)"
has "changing a limit inside a running period says so" "$OUT" "The running period is unchanged"
eq "lowering a limit keeps the running period" "$(field "$(limit_rec test-user1)" 3)" "$T0"
lu enforce > /dev/null
if wait_dead "$LAST_PID"; then ok "lowering the limit below the usage disconnects the user"; else bad "lowered limit did not disconnect the user"; fi

# ================================================================
# 8. No limit: never blocked
# ================================================================
fresh; add_user test-user1
set_totals test-user1 999999999999999 999999999999999
eq "no limit: the gate lets the user in" "$(gate_rc test-user1)" "0"
eq "no limit: no row in the limits list" "$(lu limits)" ""
eq "no limit: the gate creates no record" "$(cat "$TMP/state/limits.db")" ""
eq "no limit: totals are left alone" "$(totals_row test-user1)" "test-user1 999999999999999 999999999999999"
# a user who is BLOCKED is let in again the moment the limit is cleared
put_limit test-user1 1000 "$T0"
FAKE_NOW=$((T0 + DAY))
eq "over the limit: refused" "$(gate_rc test-user1)" "3"
lu limit test-user1 clear > /dev/null
eq "limit cleared: let in again at once" "$(gate_rc test-user1)" "0"
eq "limit cleared: totals were not reset" "$(totals_row test-user1)" "test-user1 999999999999999 999999999999999"
# the gate for names it has never heard of
eq "gate with an empty user name: let in" "$(gate_rc "")" "0"
eq "gate for an unknown name: let in" "$(gate_rc test-nobody)" "0"

# ================================================================
# 9. The panel: limit, used, remaining, period end, BLOCKED, unlimited
# ================================================================
fresh
for n in 1 2 3 4 5; do add_user "test-user$n"; done
put_limit test-user1 $((10 * GB)) "$T0";   set_totals test-user1 $((2 * GB)) $((2 * GB))  # 4 GB of 10, ok
put_limit test-user2 $((1 * GB)) "$T0";    set_totals test-user2 $((1 * GB)) 0            # at the limit: BLOCKED
put_limit test-user3 $((5 * GB)) 0                                                         # pending
put_limit test-user4 $((5 * GB)) $((T0 - 40 * DAY)); set_totals test-user4 1000 1000     # started 40 days ago: expired
set_totals test-user5 $((3 * GB)) 0                                                        # unlimited
FAKE_NOW=$((T0 + 1 * DAY))
USERS="$("$PANEL" users 2>&1)"
row1="$(printf '%s\n' "$USERS" | grep '^test-user1 ')"
row2="$(printf '%s\n' "$USERS" | grep '^test-user2 ')"
row3="$(printf '%s\n' "$USERS" | grep '^test-user3 ')"
row5="$(printf '%s\n' "$USERS" | grep '^test-user5 ')"
has "panel users: limited user shows the limit" "$row1" "10.00 GB"
has "panel users: unlimited user shows 'unlimited'" "$row5" "unlimited"
hasnt "panel users: unlimited user is not BLOCKED" "$row5" "BLOCKED"
has "panel users: over-limit user is BLOCKED" "$row2" "BLOCKED"
hasnt "panel users: an ok user is not BLOCKED" "$row1" "BLOCKED"
has "panel users: used (upload + download)" "$USERS" "used 4.00 GB of 10.00 GB"
has "panel users: remaining" "$USERS" "left 6.00 GB"
has "panel users: period end date" "$USERS" "period ends 2027-02-14 08:00 UTC"
has "panel users: BLOCKED line says until when" "$USERS" "BLOCKED: used 1.00 GB of 1.00 GB, left 0.00 B - blocked until the period ends 2027-02-14 08:00 UTC"
has "panel users: pending period" "$USERS" "starts at the first connection"
has "panel users: expired period" "$USERS" "period ended 2027-01-05"
has "panel users: a pending user shows their limit" "$row3" "5.00 GB"
hasnt "panel users: never prints passwords" "$USERS" "test-pass"
CARD="$("$PANEL" card test-user1 2>&1)"
has "card: limit" "$CARD" "Data limit:               10.00 GB per 30 days"
has "card: used" "$CARD" "Used:                     4.00 GB"
has "card: remaining" "$CARD" "Remaining:                6.00 GB"
has "card: period end" "$CARD" "Period ends:              2027-02-14 08:00 UTC"
has "card: status OK" "$CARD" "Status:                   OK"
CARD="$("$PANEL" card test-user2 2>&1)"
has "card: BLOCKED status" "$CARD" "Status:                   BLOCKED"
CARD="$("$PANEL" card test-user5 2>&1)"
has "card: unlimited user" "$CARD" "Data limit:               unlimited"
has "card: unlimited user still shows usage" "$CARD" "Used:                     3.00 GB"
hasnt "card: unlimited user is not BLOCKED" "$CARD" "BLOCKED"

# the panel's `limit` command goes through l2tp-user, so both always agree
fresh; add_user test-user1
OUT="$("$PANEL" limit test-user1 12.5 2>&1)"; rc=$?
eq "ezl2tp limit <user> 12.5: exits 0" "$rc" "0"
eq "ezl2tp limit <user> 12.5: l2tp-user stored it" "$(limit_rec test-user1)" "test-user1 13421772800 0"
has "ezl2tp limit <user> 12.5: output comes from l2tp-user" "$OUT" "12.50 GB"
has "panel users: shows the new limit before the first connection" "$("$PANEL" users 2>&1)" "12.50 GB"
"$PANEL" limit test-user1 clear > /dev/null 2>&1
eq "ezl2tp limit <user> clear: the limit is gone" "$(limit_rec test-user1)" ""
has "panel users: unlimited again" "$("$PANEL" users 2>&1)" "unlimited"
"$PANEL" limit > /dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ]; then ok "ezl2tp limit without arguments is an error"; else bad "ezl2tp limit without arguments succeeded"; fi
"$PANEL" limit test-user1 > /dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ]; then ok "ezl2tp limit <user> without a value is an error"; else bad "ezl2tp limit <user> without a value succeeded"; fi
"$PANEL" limit test-user1 banana > /dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ]; then ok "ezl2tp limit <user> banana is an error"; else bad "ezl2tp limit <user> banana succeeded"; fi
eq "bad values through the panel store nothing" "$(limit_rec test-user1)" ""

# An OLD l2tp-user (no limits marker) would take "limit" for a NEW USERNAME.
# The panel must refuse and never send it.
cat > "$TMP/l2tp-user-old" <<STUB
#!/bin/bash
echo "\$*" >> "$TMP/old-calls"
STUB
chmod +x "$TMP/l2tp-user-old"
: > "$TMP/old-calls"
OUT="$(EZL2TP_L2TP_USER="$TMP/l2tp-user-old" "$PANEL" limit test-user1 5 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then ok "old l2tp-user: ezl2tp limit refuses"; else bad "old l2tp-user: ezl2tp limit did not refuse"; fi
has "old l2tp-user: tells the admin to run install.sh again" "$OUT" "install.sh"
EZL2TP_L2TP_USER="$TMP/l2tp-user-old" "$PANEL" users > /dev/null 2>&1
eq "old l2tp-user: the panel never sends it limit/limits" "$(grep -cE '^limits?( |$)' "$TMP/old-calls")" "0"
has "old l2tp-user: users shows everybody as unlimited" "$(EZL2TP_L2TP_USER="$TMP/l2tp-user-old" "$PANEL" users 2>&1)" "unlimited"

exit "$fail"
