#!/bin/bash
# Tests for the ezl2tp panel redesign (menus only; data-limit enforcement is
# covered by limits-test.sh and is not touched by the redesign):
#   - the main menu is exactly the nine items, nothing after the names, and
#     the old top-level Users / Bandwidth / Add / Delete / Card items are gone
#   - User Management > Show all users: one numbered table, green rows for
#     online users and red rows for offline ones, the same numbers as
#     "l2tp-user stats"; picking a number opens that user's menu
#   - every per-user action: card, change password, set / clear limit,
#     reset data, disconnect now, delete (with the YES guards)
#   - Add user: Enter = 1 GB, 0 or clear = unlimited, existing users untouched
#   - Backup: create (0700, the installer's set plus the extra files, only the
#     path is printed), list, restore (YES guard, backs up first, restarts)
#   - Check For Updates: up to date / update available / old install with no
#     recorded version / GitHub unreachable / confirm guard
#   - Uninstall: exact-YES guard, backup first, the four units stopped and
#     disabled, panel and CLI removed, backup kept
#   - one-shot commands (status, users, card, ...) keep working
#
# This runs the REAL l2tp-user from install.sh with every path rewritten into a
# temp directory, and ipsec, iptables, ip, systemctl and curl replaced by stubs.
# ALL DATA HERE IS FAKE TEST DATA: users are test-*, addresses come from the
# documentation ranges or the VPN pool this project defines (10.99.*). Never
# paste real server output into this file.
#
# Usage: bash tests/panel-test.sh [path-to-ezl2tp]
#
# shellcheck disable=SC2015,SC2012,SC2010,SC2016,SC2317
# (SC2015: "cond && ok || bad" is the check idiom here and ok() cannot fail;
#  SC2012/SC2010: ls on names this test made itself; SC2016: patterns that
#  must stay literal; SC2317: functions called through other functions)
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PANEL_SRC="${1:-$ROOT/ezl2tp}"
TMP="$(mktemp -d)"
trap 'pkill -f "$TMP/pppd" 2>/dev/null; rm -rf "$TMP"' EXIT
fail=0

ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
eq() { # eq <name> <actual> <expected>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1"; echo "    expected: $3"; echo "    actual:   $2"; fi
}
has() { # has <name> <haystack> <needle>
  if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1 (missing: $3)"; echo "    in: $2" | head -40; fi
}
hasnt() {
  if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1 (found: $3)"; else ok "$1"; fi
}
hasline() { # hasline <name> <haystack> <exact line>
  if printf '%s\n' "$2" | grep -qxF -- "$3"; then ok "$1"; else bad "$1 (no line exactly: $3)"; fi
}

# ---- fake server tree: $R is "/" of the fake server ----
R="$TMP/root"
BK="$TMP/backups"
LU="$R/usr/local/bin/l2tp-user"
PANEL="$R/usr/local/bin/ezl2tp"
mkdir -p "$R/usr/local/bin" "$R/usr/local/sbin" "$R/etc/ppp" "$R/etc/xl2tpd" "$R/etc/sysctl.d" \
  "$TMP/bin" "$BK"

extract() { # extract <install path> <heredoc tag>
  awk -v tgt="$1" -v tag="$2" '
    $0 == "cat > " tgt " <<'\''" tag "'\''" { f = 1; next }
    $0 == tag { f = 0 }
    f' "$ROOT/install.sh"
}
extract /usr/local/bin/l2tp-user USER_SCRIPT | sed \
  -e "s#/var/log/vpn-usage#$R/var/log/vpn-usage#g" \
  -e "s#/var/lib/easyl2tp#$R/var/lib/easyl2tp#g" \
  -e "s#/run/vpn-sessions#$R/run/vpn-sessions#g" \
  -e "s#^RUN_DIR=\"/run\"#RUN_DIR=\"$R/run\"#" \
  -e "s#/sys/class/net#$R/sys/class/net#g" \
  -e "s#/etc/ppp/chap-secrets#$R/etc/ppp/chap-secrets#g" \
  -e "s#/etc/ppp/pap-secrets#$R/etc/ppp/pap-secrets#g" \
  -e "s#/etc/ipsec.conf#$R/etc/ipsec.conf#g" \
  -e "s#/etc/ipsec.secrets#$R/etc/ipsec.secrets#g" \
  -e "s#/etc/xl2tpd/l2tp-secrets#$R/etc/xl2tpd/l2tp-secrets#g" > "$LU"
chmod +x "$LU"
if [ ! -s "$LU" ]; then echo "FAIL: could not extract l2tp-user from install.sh"; exit 1; fi
# Safety: never let this test touch the real system.
if grep -E '/var/log/vpn-usage|/var/lib/easyl2tp|/run/|/sys/class/net|/etc/ppp/|/etc/ipsec|/etc/xl2tpd' "$LU" | grep -vqE "$R"; then
  echo "FAIL: path rewrite incomplete; refusing to run"; exit 1
fi
cp "$PANEL_SRC" "$PANEL"; chmod +x "$PANEL"
cp "$LU" "$TMP/l2tp-user.keep"
bash -n "$PANEL" || { echo "FAIL: panel syntax"; exit 1; }

# ---- stubs ----
cat > "$TMP/bin/ipsec" <<'STUB'
#!/bin/bash
echo "$*" >> "$IPSEC_CALLS"
[ "${1:-}" = statusall ] && cat "$STATUSALL_FILE" 2>/dev/null
exit 0
STUB
cat > "$TMP/bin/iptables" <<'STUB'
#!/bin/bash
exit 0
STUB
printf '#!/bin/bash\nexit 1\n' > "$TMP/bin/ip"
cat > "$TMP/bin/systemctl" <<'STUB'
#!/bin/bash
echo "$*" >> "$SYSTEMCTL_CALLS"
[ "${1:-}" = is-active ] && echo active
exit 0
STUB
# curl: the GitHub API answers with $FAKE_SHA_FILE (22 = unreachable), the raw
# install.sh URL with $FAKE_INSTALLER; everything else fails at once.
cat > "$TMP/bin/curl" <<'STUB'
#!/bin/bash
out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -H|--max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  https://api.github.com/repos/*/commits/*) [ -s "$FAKE_SHA_FILE" ] || exit 22; cat "$FAKE_SHA_FILE" ;;
  https://raw.githubusercontent.com/*/install.sh) [ -f "$FAKE_INSTALLER" ] || exit 22; cp "$FAKE_INSTALLER" "$out" ;;
  *) exit 7 ;;
esac
STUB
chmod +x "$TMP/bin/"*
cp "$(command -v sleep)" "$TMP/pppd"
PATH="$TMP/bin:$PATH"
export PATH
export IPSEC_CALLS="$TMP/ipsec-calls" SYSTEMCTL_CALLS="$TMP/systemctl-calls" STATUSALL_FILE="$TMP/statusall.txt"
export FAKE_SHA_FILE="$TMP/fake-sha" FAKE_INSTALLER="$TMP/fake-install.sh" INSTALLER_LOG="$TMP/installer-log"

# ---- panel environment: everything points into the fake server ----
export EZL2TP_CHAP="$R/etc/ppp/chap-secrets" EZL2TP_IPSEC_SECRETS="$R/etc/ipsec.secrets" \
  EZL2TP_L2TP_SECRETS="$R/etc/xl2tpd/l2tp-secrets" EZL2TP_TOTALS_DB="$R/var/log/vpn-usage/totals.db" \
  EZL2TP_SESSIONS_LOG="$R/var/log/vpn-usage/sessions.log" EZL2TP_SESSIONS_DIR="$R/run/vpn-sessions" \
  EZL2TP_L2TP_USER="$LU" EZL2TP_RUN_DIR="$R/run" EZL2TP_ROOT="$R" EZL2TP_BACKUP_ROOT="$BK" \
  EZL2TP_VERSION_FILE="$R/var/lib/easyl2tp/version" EZL2TP_ALLOW_NONROOT=1 EZL2TP_RESTART_WAIT=0 \
  EZL2TP_COLOR=never
unset EASYL2TP_BRANCH

GB=1073741824
GREEN=$'\033[32m'
RED=$'\033[31m'
SHA_OLD="1111111111111111111111111111111111111111"
SHA_NEW="2222222222222222222222222222222222222222"

# ---- helpers ----
# panel <line>...   one argument = one line typed at the panel. EOF ends it.
panel() { printf '%s\n' "$@" | timeout 60 bash "$PANEL" 2>&1; }
add_user() { printf '"%s" l2tpd "test-pass-%s" *\n' "$1" "$1" >> "$R/etc/ppp/chap-secrets"; }
set_totals() { printf '%s %s %s\n' "$1" "$2" "$3" >> "$R/var/log/vpn-usage/totals.db"; }
put_limit() { printf '%s %s %s\n' "$1" "$2" "$3" >> "$R/var/lib/easyl2tp/limits.db"; }
limit_rec() { awk -v u="$1" '$1 == u' "$R/var/lib/easyl2tp/limits.db"; }
pass_of() { awk -v u="$1" '{ gsub(/"/, ""); if ($1 == u) print $3 }' "$R/etc/ppp/chap-secrets"; }
has_user() { [ -n "$(pass_of "$1")" ]; }
ppp_dev() { mkdir -p "$R/sys/class/net/$1/statistics"; echo "$2" > "$R/sys/class/net/$1/statistics/rx_bytes"; echo "$3" > "$R/sys/class/net/$1/statistics/tx_bytes"; }
LAST_PID=""
fake_pppd() { # fake_pppd <pppN> <user> <peer>: a process called pppd, its pid file, its session file
  "$TMP/pppd" 300 > /dev/null 2>&1 &
  LAST_PID=$!
  printf '%s\n%s\n' "$LAST_PID" "$1" > "$R/run/$1.pid"
  printf '%s %s\n' "$2" "$3" > "$R/run/vpn-sessions/$1"
}
alive() { local st; st="$(awk '{ print $3 }' "/proc/$1/stat" 2>/dev/null)"; [ -n "$st" ] && [ "$st" != "Z" ]; }
wait_dead() { for _ in $(seq 1 40); do alive "$1" || return 0; sleep 0.1; done; return 1; }
calls() { cat "$SYSTEMCTL_CALLS" 2>/dev/null; }
backups() { ls -d "$BK"/easyl2tp-backup-* 2>/dev/null | wc -l | tr -d ' '; }

# A fresh fake server: test-aa online (L2TP), test-bb offline, test-cc offline
# and over its limit (BLOCKED).
fresh() {
  pkill -f "$TMP/pppd" 2>/dev/null
  # The uninstall test removes the panel and the CLI: put both back.
  cp "$TMP/l2tp-user.keep" "$LU"; cp "$PANEL_SRC" "$PANEL"; chmod +x "$LU" "$PANEL"
  rm -rf "${R:?}/var" "${R:?}/run" "${R:?}/sys" "${BK:?}" "${R:?}/etc/ppp/"* "${R:?}/etc/xl2tpd/"* "${R:?}/etc/ipsec."* \
    "$TMP/statusall.txt" "$IPSEC_CALLS" "$SYSTEMCTL_CALLS" "$FAKE_SHA_FILE" "$FAKE_INSTALLER" "$INSTALLER_LOG"
  mkdir -p "$R/var/log/vpn-usage" "$R/var/lib/easyl2tp" "$R/run/vpn-sessions" "$R/sys/class/net" "$BK"
  : > "$R/var/log/vpn-usage/totals.db"
  printf '2026-01-01 10:00:00 | CONNECT | L2TP(ppp0) | test-aa | Session started\n' > "$R/var/log/vpn-usage/sessions.log"
  : > "$R/etc/ppp/chap-secrets"; : > "$R/etc/ppp/pap-secrets"
  printf 'conn l2tp-psk\n  leftid=192.0.2.10\n' > "$R/etc/ipsec.conf"
  echo '* * test-tun-pass' > "$R/etc/xl2tpd/l2tp-secrets"
  printf '"test-aa" : PSK "test-pass-test-aa"\n: PSK "test-master-psk"\n' > "$R/etc/ipsec.secrets"
  printf 'conn x\n' > "$R/etc/xl2tpd/xl2tpd.conf"; printf 'noauth\n' > "$R/etc/ppp/options.xl2tpd"
  printf 'x\n' > "$R/etc/strongswan.conf"; printf 'x\n' > "$R/etc/sysctl.d/99-l2tp.conf"
  printf '#!/bin/bash\n' > "$R/usr/local/sbin/l2tp-fw.sh"
  : > "$R/var/lib/easyl2tp/limits.db"
  : > "$TMP/statusall.txt"; : > "$IPSEC_CALLS"; : > "$SYSTEMCTL_CALLS"
  add_user test-aa; add_user test-bb; add_user test-cc
  set_totals test-aa 1000 2000; set_totals test-bb 500 600; set_totals test-cc 2000 3000
  put_limit test-cc 1000 "$(date +%s)"          # used 5000 >= 1000: BLOCKED
  ppp_dev ppp0 1500000 4500000
  printf 'test-aa 10.99.0.10\n' > "$R/run/vpn-sessions/ppp0"
}

# ================================================================
# 1. Main menu: exactly the nine items
# ================================================================
fresh
OUT="$(panel 0)"
MENU="$(printf '%s\n' "$OUT" | grep -E '^[0-9] ')"
EXPECT="1 Status
2 User Management
3 Live sessions
4 Logs
5 Restart services
6 Backup
7 Check For Updates
8 Uninstall
0 Exit"
eq "main menu: exactly the nine items, nothing after the names" "$MENU" "$EXPECT"
for old in "Bandwidth stats" "Users (online" "Delete user" "Add user" "Show user card" "Session logs" "Restart VPN services" "data limit"; do
  hasnt "main menu: old item gone ($old)" "$OUT" "$old"
done
hasnt "main menu: no ') ' numbering" "$OUT" "1) "
has "main menu: Bye on 0" "$OUT" "Bye."

# End of input ends the panel; it must not spin on empty answers.
if OUT="$(printf '' | timeout 10 bash "$PANEL" 2>&1)"; then ok "end of input ends the panel"; else bad "panel did not end on end of input (rc=$?)"; fi
OUT="$(panel 9 0)"
has "invalid choice is reported" "$OUT" "Invalid choice."

# ================================================================
# 2. User Management menu
# ================================================================
fresh
OUT="$(panel 2 0 0)"
UM="$(printf '%s\n' "$OUT" | awk '/^  User Management$/ { f = 1 } f && /^[0-9] /' | head -3)"
eq "user management: Show all users, Add user, Back" "$UM" "1 Show all users
2 Add user
0 Back"

# ================================================================
# 3. Show all users: numbered, green / red, same numbers as stats
# ================================================================
fresh
OUT="$(panel 2 1 0 0 0)"
has "table: has the # column" "$OUT" "  #  USERNAME"
has "table: columns" "$OUT" "STATUS"
has "table: usage columns" "$OUT" "UPLOAD"
has "table: limit column" "$OUT" "LIMIT"
ROW1="$(printf '%s\n' "$OUT" | grep -E '^ +1  test-aa')"
ROW2="$(printf '%s\n' "$OUT" | grep -E '^ +2  test-bb')"
ROW3="$(printf '%s\n' "$OUT" | grep -E '^ +3  test-cc')"
has "table: row 1 is test-aa, ONLINE" "$ROW1" "ONLINE"
has "table: row 2 is test-bb, offline" "$ROW2" "offline"
has "table: row 2 is unlimited" "$ROW2" "unlimited"
has "table: row 3 is test-cc, BLOCKED" "$ROW3" "BLOCKED"
has "table: row 3 shows its limit" "$ROW3" "1000.00 B"
has "table: select prompt" "$OUT" "Select a user number"
hasnt "table: no passwords" "$OUT" "test-pass"
hasnt "table: no colors when EZL2TP_COLOR=never" "$OUT" $'\033'

# Same totals as "l2tp-user stats": live bytes of ppp0 plus totals.db.
STATS="$("$LU" stats)"
for u in test-aa test-bb test-cc; do
  line="$(printf '%s\n' "$STATS" | grep "^$u ")"
  up="$(awk -F'|' '{ gsub(/^ +| +$/, "", $2); print $2 }' <<< "$line")"
  down="$(awk -F'|' '{ gsub(/^ +| +$/, "", $3); print $3 }' <<< "$line")"
  tot="$(awk -F'|' '{ gsub(/^ +| +$/, "", $4); print $4 }' <<< "$line")"
  row="$(printf '%s\n' "$OUT" | grep -E "^ +[0-9]+  $u ")"
  has "table = stats: $u upload $up" "$row" "$up"
  has "table = stats: $u download $down" "$row" "$down"
  has "table = stats: $u total $tot" "$row" "$tot"
done
has "table: live bytes counted (test-aa upload = totals + ppp0 rx)" "$ROW1" "1.43 MB"

# The one-shot "users" is the same table without numbers.
ONE="$(bash "$PANEL" users 2>&1)"
has "one-shot users: still works" "$ONE" "test-aa"
hasnt "one-shot users: no # column" "$ONE" "  #  USERNAME"

# Colors: green for the online row, red for offline rows.
COLOR_OUT="$(printf '%s\n' 2 1 0 0 0 | EZL2TP_COLOR=always timeout 60 bash "$PANEL" 2>&1)"
has "color: online row is green" "$COLOR_OUT" "${GREEN}  1  test-aa"
has "color: offline row is red" "$COLOR_OUT" "${RED}  2  test-bb"
has "color: blocked offline row is red" "$COLOR_OUT" "${RED}  3  test-cc"
hasnt "color: online row is not red" "$COLOR_OUT" "${RED}  1  test-aa"
hasnt "color: offline row is not green" "$COLOR_OUT" "${GREEN}  2  test-bb"

# ================================================================
# 4. Numbered select opens that user's menu
# ================================================================
OUT="$(panel 2 1 2 0 0 0 0)"
has "select 2: opens test-bb" "$OUT" "User: test-bb"
UMENU="$(printf '%s\n' "$OUT" | awk '/User: test-bb/ { f = 1 } f && /^[0-9] /' | head -7)"
eq "user menu: the seven items" "$UMENU" "1 Show card
2 Change password
3 Set / clear data limit
4 Reset data
5 Disconnect now
6 Delete user
0 Back"
OUT="$(panel 2 1 3 0 0 0 0)"
has "select 3: opens test-cc" "$OUT" "User: test-cc"
OUT="$(panel 2 1 9 0 0 0)"
has "select 9: out of range" "$OUT" "Out of range."
OUT="$(panel 2 1 abc 0 0 0)"
has "select abc: invalid" "$OUT" "Invalid choice."

# ================================================================
# 5. Per-user actions
# ================================================================
# 5.1 Show card (answers: 2 1 <n> | 1 <Enter> | 0 back-table 0 back-um 0 back-main 0 exit)
fresh
OUT="$(panel 2 1 2 1 "" 0 0 0 0)"
has "card: for test-bb" "$OUT" "Card for: test-bb"
has "card: own password" "$OUT" "test-pass-test-bb"
hasnt "card: not another user's password" "$OUT" "test-pass-test-aa"
has "card: unlimited" "$OUT" "Data limit:               unlimited"

# 5.2 Change password
fresh
put_limit test-bb $((5 * GB)) 0
OUT="$(panel 2 1 2 2 "test-newpass-1" "" 0 0 0 0)"
eq "password: chap-secrets has the new one" "$(pass_of test-bb)" "test-newpass-1"
has "password: message" "$OUT" "Password changed for test-bb"
has "password: new card shown" "$OUT" "test-newpass-1"
has "password: ipsec.secrets updated" "$(cat "$R/etc/ipsec.secrets")" '"test-bb" : PSK "test-newpass-1"'
hasnt "password: old one gone from ipsec.secrets" "$(cat "$R/etc/ipsec.secrets")" "test-pass-test-bb"
eq "password: limit kept" "$(limit_rec test-bb)" "test-bb $((5 * GB)) 0"
eq "password: other users untouched" "$(pass_of test-aa)" "test-pass-test-aa"
fresh
OUT="$(panel 2 1 2 2 "bad pass" "" 0 0 0 0)"
has "password: invalid is refused" "$OUT" "Invalid password"
eq "password: invalid changes nothing" "$(pass_of test-bb)" "test-pass-test-bb"
fresh
panel 2 1 2 2 "" "" 0 0 0 0 > /dev/null
if printf '%s' "$(pass_of test-bb)" | grep -Eq '^[0-9a-f]{12}$'; then ok "password: Enter gives a random 12-hex one"; else bad "password: Enter did not give a random one ($(pass_of test-bb))"; fi
has_user test-aa && has_user test-cc && ok "password: other users still exist" || bad "password: another user disappeared"

# 5.3 Set / clear data limit
fresh
OUT="$(panel 2 1 2 3 5 "" 0 0 0 0)"
eq "limit: 5 GB stored in bytes" "$(limit_rec test-bb)" "test-bb $((5 * GB)) 0"
has "limit: message" "$OUT" "Limit for test-bb set to 5.00 GB"
panel 2 1 2 3 12.5 "" 0 0 0 0 > /dev/null
eq "limit: decimals" "$(limit_rec test-bb)" "test-bb 13421772800 0"
panel 2 1 2 3 clear "" 0 0 0 0 > /dev/null
eq "limit: clear removes it" "$(limit_rec test-bb)" ""
panel 2 1 2 3 5 "" 0 0 0 0 > /dev/null
panel 2 1 2 3 0 "" 0 0 0 0 > /dev/null
eq "limit: 0 means unlimited" "$(limit_rec test-bb)" ""
panel 2 1 2 3 5 "" 0 0 0 0 > /dev/null
OUT="$(panel 2 1 2 3 abc "" 0 0 0 0)"
has "limit: invalid is refused" "$OUT" "Invalid limit 'abc'"
eq "limit: invalid changes nothing" "$(limit_rec test-bb)" "test-bb $((5 * GB)) 0"
OUT="$(panel 2 1 2 3 "" "" 0 0 0 0)"
has "limit: Enter cancels" "$OUT" "Cancelled."
eq "limit: Enter changes nothing" "$(limit_rec test-bb)" "test-bb $((5 * GB)) 0"
eq "limit: another user's limit untouched" "$(limit_rec test-cc | cut -d' ' -f1-2)" "test-cc 1000"

# 5.4 Reset data
fresh
put_limit test-bb $((5 * GB)) 0
OUT="$(panel 2 1 2 4 NO "" 0 0 0 0)"
has "reset: NO cancels" "$OUT" "Cancelled."
has "reset: NO keeps the usage" "$(cat "$R/var/log/vpn-usage/totals.db")" "test-bb 500 600"
OUT="$(panel 2 1 2 4 yes "" 0 0 0 0)"
has "reset: lowercase yes cancels" "$OUT" "Cancelled."
OUT="$(panel 2 1 2 4 YES "" 0 0 0 0)"
has "reset: YES resets" "$OUT" "Reset bandwidth usage for user: test-bb"
eq "reset: test-bb usage is gone" "$(grep -c '^test-bb ' "$R/var/log/vpn-usage/totals.db")" "0"
has "reset: other users keep their usage" "$(cat "$R/var/log/vpn-usage/totals.db")" "test-aa 1000 2000"
eq "reset: the limit itself is kept" "$(limit_rec test-bb | cut -d' ' -f1-2)" "test-bb $((5 * GB))"

# 5.5 Disconnect now: L2TP (a process called pppd) and IKEv2 (ipsec down)
fresh
fake_pppd ppp0 test-aa 10.99.0.10
PPID_A="$LAST_PID"
OUT="$(panel 2 1 1 5 "" 0 0 0 0)"
has "disconnect: L2TP session reported" "$OUT" "Disconnected L2TP(ppp0)"
if wait_dead "$PPID_A"; then ok "disconnect: the pppd process was ended"; else bad "disconnect: pppd still running"; fi
has "disconnect: says they can reconnect" "$OUT" "can reconnect right away"
fresh
printf 'test-aa 10.99.1.10\n' > "$R/run/vpn-sessions/ikev2_10.99.1.10"
rm -f "$R/run/vpn-sessions/ppp0"
cat > "$TMP/statusall.txt" <<'SA'
 ikev2-psk[7]: ESTABLISHED 6 minutes ago, 192.0.2.10[198.51.100.20]...203.0.113.5[test-aa]
 ikev2-psk{9}:  AES_CBC_128/HMAC_SHA2_256_128, 1000 bytes_i (8 pkts, 1s ago), 2000 bytes_o (7 pkts, 1s ago), rekeying disabled
 ikev2-psk{9}:   0.0.0.0/0 === 10.99.1.10/32
 ikev2-psk[8]: ESTABLISHED 2 minutes ago, 192.0.2.10[198.51.100.20]...203.0.113.6[test-bb]
SA
OUT="$(panel 2 1 1 5 "" 0 0 0 0)"
has "disconnect: IKEv2 session reported" "$OUT" "Disconnected IKEv2 (sa 7)"
eq "disconnect: ipsec down only for that user's SA" "$(grep '^down' "$IPSEC_CALLS")" "down ikev2-psk[7]"
fresh
OUT="$(panel 2 1 2 5 "" 0 0 0 0)"
has "disconnect: offline user" "$OUT" "test-bb is not connected."
eq "disconnect: offline user, no ipsec down" "$(grep -c '^down' "$IPSEC_CALLS")" "0"

# 5.6 Delete user
fresh
put_limit test-bb $((5 * GB)) 0
OUT="$(panel 2 1 2 6 NO "" 0 0 0 0 0)"
has "delete: NO cancels" "$OUT" "Cancelled."
has_user test-bb && ok "delete: NO keeps the user" || bad "delete: user gone after NO"
panel 2 1 2 6 YES "" 0 0 0 > /dev/null
has_user test-bb && bad "delete: YES did not delete" || ok "delete: YES deletes the user"
eq "delete: their limit is removed too" "$(limit_rec test-bb)" ""
has_user test-aa && has_user test-cc && ok "delete: other users stay" || bad "delete: another user disappeared"
OUT="$(panel 2 1 2 6 YES "" 0 0 0)"
hasnt "delete: user is not in the refreshed table" "$(printf '%s\n' "$OUT" | tail -n 12)" "test-bb"

# ================================================================
# 6. Add user
# ================================================================
fresh
# name, Enter = random password, Enter = default limit
OUT="$(panel 2 2 test-dd "" "" "" 0 0)"
has_user test-dd && ok "add: user created" || bad "add: user not created"
if printf '%s' "$(pass_of test-dd)" | grep -Eq '^[0-9a-f]{12}$'; then ok "add: Enter gives a random password"; else bad "add: no random password"; fi
eq "add: Enter defaults to 1 GB" "$(limit_rec test-dd)" "test-dd $GB 0"
has "add: card is shown" "$OUT" "Card for: test-dd"
has "add: card shows 1.00 GB" "$OUT" "1.00 GB per 30 days"
has "add: card has the new password" "$OUT" "$(pass_of test-dd)"
eq "add: existing unlimited user untouched" "$(limit_rec test-aa)" ""
eq "add: existing limited user untouched" "$(limit_rec test-cc | cut -d' ' -f1-2)" "test-cc 1000"
OUT="$(panel 2 2 test-ee test-pass-ee1 0 "" 0 0)"
eq "add: own password used" "$(pass_of test-ee)" "test-pass-ee1"
eq "add: 0 means unlimited" "$(limit_rec test-ee)" ""
has "add: card says unlimited" "$OUT" "Data limit:               unlimited"
panel 2 2 test-ff "" clear "" 0 0 > /dev/null
eq "add: clear means unlimited" "$(limit_rec test-ff)" ""
has_user test-ff && ok "add: clear still creates the user" || bad "add: test-ff missing"
panel 2 2 test-gg "" 2.5 "" 0 0 > /dev/null
eq "add: 2.5 GB" "$(limit_rec test-gg)" "test-gg 2684354560 0"
OUT="$(panel 2 2 "bad name" 0 0)"
has "add: invalid name refused" "$OUT" "Invalid username"
has_user "bad name" && bad "add: bad name created" || ok "add: bad name creates nothing"
OUT="$(panel 2 2 test-hh "" abc 0 0)"
has "add: invalid limit refused" "$OUT" "Invalid limit 'abc'"
has_user test-hh && bad "add: user created despite a bad limit" || ok "add: a bad limit creates nothing"
OUT="$(panel 2 2 test-hh "a b" "" 0 0)"
has "add: invalid password refused" "$OUT" "Invalid password"
has_user test-hh && bad "add: user created despite a bad password" || ok "add: a bad password creates nothing"
BEFORE="$(cat "$R/etc/ppp/chap-secrets")"
OUT="$(panel 2 2 test-aa "" "" "" 0 0)"
has "add: existing name refused" "$OUT" "already exists"
eq "add: existing name changes nothing" "$(cat "$R/etc/ppp/chap-secrets")" "$BEFORE"
# An l2tp-user without limit support must not create a user the admin thinks is limited.
OLD="$TMP/old-l2tp-user"
printf '#!/bin/bash\necho "$*" >> "%s/old-calls"\n' "$TMP" > "$OLD"; chmod +x "$OLD"
OUT="$(printf '%s\n' 2 2 test-ii "" "" 0 0 | EZL2TP_L2TP_USER="$OLD" timeout 60 bash "$PANEL" 2>&1)"
has "add: old l2tp-user without limits is refused up front" "$OUT" "does not know data limits"
eq "add: and it was never called" "$(cat "$TMP/old-calls" 2>/dev/null)" ""

# ================================================================
# 7. Backup
# ================================================================
fresh
put_limit test-bb $((5 * GB)) 0
OUT="$(panel 6 1 "" 0 0)"
BDIR="$(ls -d "$BK"/easyl2tp-backup-* 2>/dev/null | head -1)"
has "backup: path printed" "$OUT" "Backup created: $BDIR"
[ -d "$BDIR" ] && ok "backup: folder exists under the backup root" || bad "backup: no folder"
eq "backup: permissions 0700" "$(stat -c %a "$BDIR")" "700"
eq "backup: no group/other access anywhere inside" "$(find "$BDIR" -type d -perm /077 | wc -l | tr -d ' ')" "0"
hasnt "backup: no secrets printed (password)" "$OUT" "test-pass"
hasnt "backup: no secrets printed (PSK)" "$OUT" "test-master-psk"
hasnt "backup: no secrets printed (tunnel password)" "$OUT" "test-tun-pass"
# The set: everything the installer backs up, plus panel, CLI, firewall script,
# totals, limits and sessions log.
INSTALLER_SET="$(grep -E '^backup_file /' "$ROOT/install.sh" | awk '{ print $2 }')"
n=0
for f in $INSTALLER_SET; do
  n=$((n + 1))
  [ -f "$BDIR$f" ] && ok "backup set: installer file $f" || bad "backup set: installer file $f missing from the backup"
done
[ "$n" -ge 9 ] && ok "backup set: read $n files from install.sh" || bad "backup set: expected >= 9 backup_file lines in install.sh, got $n"
for f in /usr/local/bin/ezl2tp /usr/local/bin/l2tp-user /usr/local/sbin/l2tp-fw.sh \
  /var/log/vpn-usage/totals.db /var/lib/easyl2tp/limits.db /var/log/vpn-usage/sessions.log; do
  [ -f "$BDIR$f" ] && ok "backup set: extra file $f" || bad "backup set: $f missing from the backup"
done
eq "backup: contents are a copy (chap-secrets)" "$(cat "$BDIR/etc/ppp/chap-secrets")" "$(cat "$R/etc/ppp/chap-secrets")"
eq "backup: contents are a copy (limits)" "$(cat "$BDIR/var/lib/easyl2tp/limits.db")" "$(cat "$R/var/lib/easyl2tp/limits.db")"
# A second one in the same second must not overwrite the first.
ONE="$(bash "$PANEL" backup 2>&1)"
eq "one-shot backup: prints only the path" "$(printf '%s\n' "$ONE" | wc -l | tr -d ' ')" "1"
case "$ONE" in "$BK"/easyl2tp-backup-*) ok "one-shot backup: the line is a path under the backup root" ;; *) bad "one-shot backup printed: $ONE" ;; esac
eq "backup: two backups, two folders" "$(backups)" "2"
# An installer-made (flat) backup is listed but not restorable by the panel.
mkdir -p "$BK/easyl2tp-backup-20200101-000000" && echo x > "$BK/easyl2tp-backup-20200101-000000/chap-secrets"
OUT="$(panel 6 2 "" 0 0)"
has "list: shows the panel backup" "$OUT" "$BDIR"
has "list: numbered" "$OUT" "  1  $BK/easyl2tp-backup-"
has "list: marks the installer's flat backup" "$OUT" "made by the installer"
ONE="$(bash "$PANEL" backups 2>&1)"
has "one-shot backups: lists" "$ONE" "$BDIR"
OUT="$(panel 6 3 1 YES "" 0 0)"
has "restore: refuses the installer's flat backup" "$OUT" "made by the installer"
rm -rf "$BK/easyl2tp-backup-20200101-000000"

# Restore: YES guard, backs up the current state first, restores, restarts.
fresh
panel 6 1 "" 0 0 > /dev/null
GOOD="$(ls -d "$BK"/easyl2tp-backup-* | head -1)"
printf '"test-zz" l2tpd "test-pass-zz" *\n' >> "$R/etc/ppp/chap-secrets"   # a change made after the backup
echo "broken" > "$R/etc/ipsec.conf"
: > "$SYSTEMCTL_CALLS"
OUT="$(panel 6 3 1 NO "" 0 0)"
has "restore: NO cancels" "$OUT" "Cancelled."
eq "restore: NO restores nothing" "$(cat "$R/etc/ipsec.conf")" "broken"
eq "restore: NO makes no extra backup" "$(backups)" "1"
eq "restore: NO restarts nothing" "$(calls)" ""
OUT="$(panel 6 3 1 yes "" 0 0)"
has "restore: lowercase yes cancels" "$OUT" "Cancelled."
eq "restore: lowercase yes restores nothing" "$(cat "$R/etc/ipsec.conf")" "broken"
OUT="$(panel 6 3 1 YES "" 0 0)"
has "restore: says the current state was saved first" "$OUT" "Current state saved first:"
eq "restore: now two backups (the one taken before restoring)" "$(backups)" "2"
PRE="$(ls -d "$BK"/easyl2tp-backup-* | grep -v "^$GOOD\$" | head -1)"
has "restore: the pre-restore backup holds the state before restoring" "$(cat "$PRE/etc/ppp/chap-secrets")" "test-zz"
has "restore: the broken file was in the pre-restore backup" "$(cat "$PRE/etc/ipsec.conf")" "broken"
eq "restore: ipsec.conf is back" "$(cat "$R/etc/ipsec.conf")" "$(cat "$GOOD/etc/ipsec.conf")"
has_user test-zz && bad "restore: chap-secrets still has the later user" || ok "restore: chap-secrets is back to the backup"
has_user test-bb && ok "restore: users from the backup are there" || bad "restore: test-bb missing"
has "restore: services restarted" "$(calls)" "restart strongswan-starter xl2tpd l2tp-firewall"
[ -x "$LU" ] && [ -x "$PANEL" ] && ok "restore: panel and CLI are still in place" || bad "restore: panel or CLI missing"
OUT="$(panel 6 3 7 0 0)"
has "restore: out-of-range number" "$OUT" "Out of range."

# No backups yet: list and restore say so.
fresh
OUT="$(panel 6 2 "" 3 0 0)"
has "list: no backups yet" "$OUT" "No backups yet"

# A backup that cannot be made says so and leaves nothing behind.
fresh
: > "$TMP/not-a-dir"
OUT="$(EZL2TP_BACKUP_ROOT="$TMP/not-a-dir/x" bash "$PANEL" backup 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "backup: failure exits non-zero" || bad "backup: failure exited 0"
has "backup: failure is reported" "$OUT" "ERROR"

# ================================================================
# 8. Check For Updates
# ================================================================
cat > "$FAKE_INSTALLER" <<'INST'
#!/bin/bash
echo "installer ran commit=${EASYL2TP_COMMIT:-none} branch=${EASYL2TP_BRANCH:-none}" >> "$INSTALLER_LOG"
echo "fake installer output"
exit 0
INST
fresh
cp "$TMP/fake-install.sh" "$TMP/fake-install.keep" 2>/dev/null || true
cat > "$FAKE_INSTALLER" <<'INST'
#!/bin/bash
echo "installer ran commit=${EASYL2TP_COMMIT:-none} branch=${EASYL2TP_BRANCH:-none}" >> "$INSTALLER_LOG"
echo "fake installer output"
exit 0
INST
# 8.1 up to date
echo "$SHA_NEW" > "$R/var/lib/easyl2tp/version"; echo "$SHA_NEW" > "$FAKE_SHA_FILE"
OUT="$(panel 7 "" 0)"
has "update: shows the installed commit" "$OUT" "Installed version: $SHA_NEW"
has "update: shows the latest commit" "$OUT" "Latest on main:   $SHA_NEW"
has "update: up to date" "$OUT" "You are up to date."
[ ! -s "$INSTALLER_LOG" ] && ok "update: up to date runs no installer" || bad "update: installer ran when up to date"
# 8.2 update available, confirm guard
echo "$SHA_OLD" > "$R/var/lib/easyl2tp/version"
OUT="$(panel 7 NO "" 0)"
has "update: available" "$OUT" "An update is available."
has "update: tells that users, secrets and limits are kept" "$OUT" "Your users, secrets and"
has "update: NO cancels" "$OUT" "Cancelled. Nothing was changed."
[ ! -s "$INSTALLER_LOG" ] && ok "update: NO runs no installer" || bad "update: installer ran after NO"
eq "update: NO takes no backup" "$(backups)" "0"
OUT="$(panel 7 y "" 0)"
has "update: only YES confirms (y cancels)" "$OUT" "Cancelled."
[ ! -s "$INSTALLER_LOG" ] && ok "update: y runs no installer" || bad "update: installer ran after y"
# 8.3 confirmed: backup first, installer from main gets the commit, panel stops
OUT="$(panel 7 YES SHOULD-NOT-BE-READ 0)"
has "update: backup first" "$OUT" "Backup created: $BK/easyl2tp-backup-"
eq "update: one backup taken" "$(backups)" "1"
has "update: the installer ran" "$(cat "$INSTALLER_LOG" 2>/dev/null)" "installer ran commit=$SHA_NEW branch=main"
has "update: installer output shown" "$OUT" "fake installer output"
has "update: finished message" "$OUT" "Update finished."
hasnt "update: the old panel stops after the installer" "$OUT" "SHOULD-NOT-BE-READ"
hasnt "update: no menu after the installer" "$(printf '%s\n' "$OUT" | sed -n '/Update finished/,$p')" "2 User Management"
# 8.4 old install: no version file
rm -f "$R/var/lib/easyl2tp/version" "$INSTALLER_LOG"
OUT="$(panel 7 NO "" 0)"
has "update (old install): not recorded, not an error" "$OUT" "not recorded (installed before version tracking)"
has "update (old install): still offers to update" "$OUT" "An update may be available"
hasnt "update (old install): no failure" "$OUT" "ERROR"
hasnt "update (old install): no shell error" "$OUT" "unbound variable"
echo unknown > "$R/var/lib/easyl2tp/version"
OUT="$(panel 7 NO "" 0)"
has "update (stamp says unknown): handled the same" "$OUT" "not recorded"
printf 'garbage\n' > "$R/var/lib/easyl2tp/version"
OUT="$(panel 7 NO "" 0)"
has "update (garbage stamp): handled the same" "$OUT" "not recorded"
rm -f "$R/var/lib/easyl2tp/version"
OUT="$(printf 'YES\n' | bash "$PANEL" update 2>&1)"; rc=$?
eq "one-shot update (old install): exits 0" "$rc" "0"
has "one-shot update (old install): installer ran" "$(cat "$INSTALLER_LOG" 2>/dev/null)" "installer ran commit=$SHA_NEW"
# 8.5 GitHub unreachable
rm -f "$FAKE_SHA_FILE" "$INSTALLER_LOG"
OUT="$(panel 7 "" 0)"
has "update (offline): says it could not read GitHub" "$OUT" "could not be read from GitHub"
has "update (offline): panel carries on to the menu" "$OUT" "Bye."
[ ! -s "$INSTALLER_LOG" ] && ok "update (offline): no installer run" || bad "update (offline): installer ran"
# 8.6 a bad download is refused
echo "$SHA_NEW" > "$FAKE_SHA_FILE"
echo "not a script" > "$FAKE_INSTALLER"
OUT="$(panel 7 YES "" 0)"
has "update (bad download): refused" "$OUT" "Could not download a valid install.sh"
has "update (bad download): the panel goes on" "$OUT" "Bye."
printf '#!/bin/bash\nif then fi (\n' > "$FAKE_INSTALLER"
OUT="$(panel 7 YES "" 0)"
has "update (syntax error in download): refused" "$OUT" "Could not download a valid install.sh"
# 8.7 installer fails: the backup path is shown
printf '#!/bin/bash\nexit 3\n' > "$FAKE_INSTALLER"
OUT="$(panel 7 YES "" 0)"
has "update (installer fails): says so" "$OUT" "The update did not finish. Your backup is at"

# The installer side: users, secrets and limits are kept on a re-run (static),
# and the version stamp is written (the block is run for real).
has "installer keeps the master PSK on re-run" "$(cat "$ROOT/install.sh")" 'IPSEC_PSK="$EXISTING_MASTER_PSK"'
has "installer keeps the tunnel password on re-run" "$(cat "$ROOT/install.sh")" 'TUNPW="$EXISTING_TUNPW"'
has "installer keeps limits.db on re-run (touch, not >)" "$(cat "$ROOT/install.sh")" 'touch /var/lib/easyl2tp/limits.db'
STAMP="$TMP/stamp.sh"
awk '/^# --- Version stamp/ { f = 1 } /^systemctl daemon-reload$/ { f = 0 } f' "$ROOT/install.sh" \
  | sed -e "s#/var/lib/easyl2tp#$TMP/stampdir#g" > "$STAMP"
if [ -s "$STAMP" ]; then ok "installer: version stamp block found"; else bad "installer: version stamp block not found"; fi
# The stamp block is install.sh code that reads SELF_DIR and PANEL_INSTALLED.
export SELF_DIR="$TMP/nogit" PANEL_INSTALLED=1
mkdir -p "$SELF_DIR"
# shellcheck source=/dev/null
( EASYL2TP_COMMIT="$SHA_NEW"; export EASYL2TP_COMMIT; . "$STAMP" )
eq "installer stamp: commit from the panel's update" "$(cat "$TMP/stampdir/version")" "$SHA_NEW"
rm -rf "$TMP/stampdir"
# shellcheck source=/dev/null
( unset EASYL2TP_COMMIT; rm -f "$FAKE_SHA_FILE"; . "$STAMP" )
eq "installer stamp: unknown when nothing can be read" "$(cat "$TMP/stampdir/version")" "unknown"
rm -rf "$TMP/stampdir"
# shellcheck source=/dev/null
( unset EASYL2TP_COMMIT; echo "$SHA_OLD" > "$FAKE_SHA_FILE"; . "$STAMP" )
eq "installer stamp: branch tip when the panel was fetched" "$(cat "$TMP/stampdir/version")" "$SHA_OLD"
eq "installer stamp: file is root-only" "$(stat -c %a "$TMP/stampdir/version")" "600"

# ================================================================
# 9. Uninstall
# ================================================================
fresh
for ans in "" yes y NO " YES" "YES "; do
  OUT="$(panel 8 "$ans" 0)"
  has "uninstall: answer '$ans' cancels" "$OUT" "Cancelled. Nothing was changed."
done
[ -x "$PANEL" ] && [ -x "$LU" ] && ok "uninstall guard: panel and CLI still there" || bad "uninstall guard: something was removed"
eq "uninstall guard: no backup taken" "$(backups)" "0"
eq "uninstall guard: no service touched" "$(calls)" ""
has "uninstall: warns first" "$OUT" "UNINSTALL easyl2tp"
# A failing backup stops the uninstall before anything is removed.
OUT="$(printf '%s\n' 8 YES 0 | EZL2TP_BACKUP_ROOT="$TMP/not-a-dir/x" timeout 60 bash "$PANEL" 2>&1)"
has "uninstall: no backup, no uninstall" "$OUT" "nothing was removed"
[ -x "$PANEL" ] && [ -x "$LU" ] && ok "uninstall (no backup): panel and CLI still there" || bad "uninstall (no backup): files removed"
eq "uninstall (no backup): no service touched" "$(calls)" ""
# The real thing.
OUT="$(panel 8 YES SHOULD-NOT-BE-READ)"
BDIR="$(ls -d "$BK"/easyl2tp-backup-* 2>/dev/null | head -1)"
has "uninstall: backup path shown" "$OUT" "Backup created: $BDIR"
[ -n "$BDIR" ] && [ -d "$BDIR" ] && ok "uninstall: backup exists" || bad "uninstall: no backup"
for s in strongswan-starter xl2tpd l2tp-firewall easyl2tp-limits.timer; do
  has "uninstall: $s stopped and disabled" "$(calls)" "disable --now $s"
done
[ ! -e "$PANEL" ] && ok "uninstall: panel removed" || bad "uninstall: panel still there"
[ ! -e "$LU" ] && ok "uninstall: CLI removed" || bad "uninstall: CLI (l2tp-user) still there"
[ -d "$BDIR" ] && [ -f "$BDIR/etc/ppp/chap-secrets" ] && [ -f "$BDIR/usr/local/bin/l2tp-user" ] && ok "uninstall: backup kept, with the CLI and the users in it" || bad "uninstall: backup missing or incomplete"
has "uninstall: says the backup is kept" "$OUT" "Your backup is kept: $BDIR"
hasnt "uninstall: the removed panel stops, nothing more is read" "$OUT" "SHOULD-NOT-BE-READ"
hasnt "uninstall: no secrets printed" "$OUT" "test-pass"
[ -f "$R/etc/ppp/chap-secrets" ] && ok "uninstall: users and secrets left on disk" || bad "uninstall: chap-secrets deleted"
# Nothing in the panel deletes backups.
if grep -nE 'rm .*(BACKUP_ROOT|easyl2tp-backup)' "$PANEL_SRC" | grep -v 'rm -rf "\$dest"'; then bad "panel: a backup is removed somewhere other than a failed half-made one"; else ok "panel: never deletes a finished backup"; fi

# ================================================================
# 10. One-shot commands keep working
# ================================================================
fresh
OUT="$(bash "$PANEL" status 2>&1)"
has "one-shot status" "$OUT" "Users:           3 total, 1 online"
OUT="$(bash "$PANEL" card test-bb 2>&1)"
has "one-shot card" "$OUT" "Card for: test-bb"
has "one-shot card: password" "$OUT" "test-pass-test-bb"
bash "$PANEL" card no-such-user > /dev/null 2>&1 && bad "one-shot card: missing user should fail" || ok "one-shot card: missing user fails"
OUT="$(bash "$PANEL" live 2>&1)"
has "one-shot live" "$OUT" "ppp0"
OUT="$(bash "$PANEL" help 2>&1)"
has "one-shot help mentions backup" "$OUT" "backup"
bash "$PANEL" limit test-bb 3 > /dev/null 2>&1
eq "one-shot limit" "$(limit_rec test-bb)" "test-bb $((3 * GB)) 0"
bash "$PANEL" add test-oo test-pass-oo1 > /dev/null 2>&1
eq "one-shot add" "$(pass_of test-oo)" "test-pass-oo1"
eq "one-shot add: no default limit (menu-only behaviour)" "$(limit_rec test-oo)" ""

exit "$fail"
