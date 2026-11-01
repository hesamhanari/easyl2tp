#!/bin/bash
# Tests for the kernel auto-fix in install.sh (ensure_ppp / kernel_fix).
#
# This runs the REAL code between "# BEGIN kernel-fix" and "# END kernel-fix"
# in install.sh, with uname, dpkg-query, apt-get, update-grub, reboot and
# sleep replaced by stubs that log what was called. Nothing here touches the
# real system. All kernel versions below are fake test data.
#
# Usage: bash tests/kernel-fix-test.sh   (from anywhere)
# The stubs below are called by the sourced install.sh code, and the KFIX_*
# variables are read by it; shellcheck cannot see either.
# shellcheck disable=SC2317,SC2034
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0

ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
expect() { local n="$1"; shift; if "$@"; then ok "$n"; else bad "$n"; fi; }

awk '/^# BEGIN kernel-fix$/ {f=1; next} /^# END kernel-fix$/ {f=0} f' "$ROOT/install.sh" > "$TMP/block.sh"
if [ ! -s "$TMP/block.sh" ]; then echo "FAIL: kernel-fix block not found in install.sh"; exit 1; fi
bash -n "$TMP/block.sh" || { echo "FAIL: kernel-fix block has a syntax error"; exit 1; }

CLOUD_VER="6.12.48+deb13-cloud-amd64"
STOCK_VER="6.12.48+deb13-amd64"
NEW_VER="6.99.0+fake1-amd64" # what the stubbed "apt-get install linux-image-amd64" installs

# Helpers that read the result of the last run().
D=""
RC=0
has_call() { grep -qE -- "$1" "$D/calls" 2>/dev/null; }
no_call() { ! has_call "$1"; }
has_out() { grep -qF -- "$1" "$D/out" 2>/dev/null; }
no_out() { ! has_out "$1"; }
line_of() { grep -nE -- "$1" "$D/calls" 2>/dev/null | head -n 1 | cut -d: -f1; }
has_call_f() { grep -qF -- "$1" "$D/calls" 2>/dev/null; }
# Nothing was installed, removed, regenerated or rebooted, and no marker was written.
no_changes() { no_call '^apt-get (install|remove)' && not_applied; }
# The cloud kernel is untouched and the machine was not rebooted. (The marker
# check is separate because some scenarios start with a marker from a past run.)
not_applied() { no_call '^apt-get remove' && no_call '^update-grub' && no_call '^reboot'; }
no_new_marker() { [ ! -f "$D/state/kernel-fix" ]; }

# run <name> [keep]
# Scenario knobs (shell variables set by the caller before run):
#   S_KERNEL      running kernel (uname -r)          S_ARCH        dpkg architecture
#   S_CFG         off = config says PPP not set, on = CONFIG_PPP=m, none = no config file
#   S_PPP_OK      1 = ppp_ready succeeds             S_TTY         1 = terminal available
#   S_ANSWER      what the user types                S_BOOT_ID     current boot id
#   S_MARKER_BOOT boot id stored in an existing kernel-fix marker (unset = no marker)
#   S_INSTALL_FAIL / S_STOCK_NO_PPP / S_REMOVE_FAIL / S_GRUB_FAIL / S_GRUB_EMPTY / S_NO_GRUB = 1
# "keep" reuses the fake system from the previous run of the same name.
run() {
  D="$TMP/sys-$1"
  if [ "${2:-}" != keep ]; then
    rm -rf "$D"
    mkdir -p "$D/boot/grub" "$D/state" "$D/modules"
    : > "$D/calls"
    printf 'linux-image-cloud-amd64\nlinux-image-%s\nlinux-image-%s\n' "$CLOUD_VER" "$STOCK_VER" > "$D/pkgs"
    [ "${S_KERNEL:-}" = "$CLOUD_VER" ] || sed -i "/cloud/d" "$D/pkgs"
    case "${S_CFG:-off}" in
      off) echo '# CONFIG_PPP is not set' > "$D/boot/config-$S_KERNEL" ;;
      on) echo 'CONFIG_PPP=m' > "$D/boot/config-$S_KERNEL" ;;
    esac
    : > "$D/boot/vmlinuz-$S_KERNEL"
    if [ -n "${S_MARKER_BOOT:-}" ]; then
      printf 'boot_id=%s\nfrom_kernel=%s\nto_kernel=%s\n' "$S_MARKER_BOOT" "$CLOUD_VER" "$NEW_VER" > "$D/state/kernel-fix"
    fi
  fi
  echo "${S_BOOT_ID:-boot-1}" > "$D/boot_id"
  (
    set -u
    # shellcheck disable=SC1091
    . "$TMP/block.sh"
    KFIX_STATE_DIR="$D/state"
    KFIX_STATE_FILE="$D/state/kernel-fix"
    KFIX_BOOT_ID_FILE="$D/boot_id"
    KFIX_BOOT_DIR="$D/boot"
    KFIX_GRUB_CFG="$D/boot/grub/grub.cfg"
    KFIX_MODULES_DIR="$D/modules"
    log() { echo "$*" >> "$D/calls"; }
    uname() { if [ "${1:-}" = "-r" ]; then echo "$S_KERNEL"; else command uname "$@"; fi; }
    dpkg() { [ "${1:-}" = "--print-architecture" ] && echo "${S_ARCH:-amd64}"; return 0; }
    dpkg-query() { # dpkg-query -W -f=<fmt> <glob>...: print "ii  <name>" for installed matches
      local name pat
      shift 2
      while read -r name; do
        for pat in "$@"; do
          # shellcheck disable=SC2053
          if [[ $name == $pat ]]; then echo "ii  $name"; break; fi
        done
      done < "$D/pkgs"
    }
    apt-get() {
      log "apt-get $*"
      case "${1:-}" in
        update) return 0 ;;
        install)
          [ "${S_INSTALL_FAIL:-0}" = 1 ] && return 100
          echo "linux-image-$NEW_VER" >> "$D/pkgs"
          : > "$D/boot/vmlinuz-$NEW_VER"
          : > "$D/boot/initrd.img-$NEW_VER"
          if [ "${S_STOCK_NO_PPP:-0}" = 1 ]; then echo '# CONFIG_PPP is not set' > "$D/boot/config-$NEW_VER"; else echo 'CONFIG_PPP=m' > "$D/boot/config-$NEW_VER"; fi
          ;;
        remove)
          [ "${S_REMOVE_FAIL:-0}" = 1 ] && return 100
          local p
          for p in "$@"; do
            case "$p" in remove|-y) continue ;; esac
            grep -vxF "$p" "$D/pkgs" > "$D/pkgs.new"; mv "$D/pkgs.new" "$D/pkgs"
          done
          rm -f "$D"/boot/*cloud*
          ;;
      esac
    }
    update-grub() {
      log "update-grub"
      [ "${S_GRUB_FAIL:-0}" = 1 ] && return 1
      : > "$KFIX_GRUB_CFG"
      [ "${S_GRUB_EMPTY:-0}" = 1 ] && return 0
      local f
      for f in "$D"/boot/vmlinuz-*; do [ -e "$f" ] && echo "linux /vmlinuz-${f##*/vmlinuz-}" >> "$KFIX_GRUB_CFG"; done
      return 0
    }
    [ "${S_NO_GRUB:-0}" = 1 ] && unset -f update-grub
    sleep() { log "sleep $*"; }
    reboot() { log "reboot"; }
    ppp_ready() { [ "${S_PPP_OK:-0}" = 1 ]; }
    kfix_have_tty() { [ "${S_TTY:-1}" = 1 ]; }
    kfix_read_answer() { log "prompt-read"; echo "[user types: ${S_ANSWER:-}]" >> "$D/typed"; printf '%s' "${S_ANSWER:-}"; }
    ensure_ppp
    echo "RETURNED: the installer would continue now"
  ) > "$D/out" 2>&1
  RC=$?
}

reset_knobs() {
  S_KERNEL="$CLOUD_VER"; S_ARCH=amd64; S_CFG=off; S_PPP_OK=0; S_TTY=1; S_ANSWER=YES; S_BOOT_ID=boot-1
  unset S_MARKER_BOOT S_INSTALL_FAIL S_STOCK_NO_PPP S_REMOVE_FAIL S_GRUB_FAIL S_GRUB_EMPTY S_NO_GRUB
}

# ---------------------------------------------------------------- PPP works
reset_knobs; S_PPP_OK=1; S_KERNEL="$STOCK_VER"; S_CFG=on
run ppp-ok
expect "PPP ok: installer continues" has_out "RETURNED"
expect "PPP ok: says OK" has_out "PPP kernel support: OK"
expect "PPP ok: no apt, grub or reboot call" test ! -s "$D/calls"
expect "PPP ok: exit status 0" test "$RC" -eq 0

# ---------------------------------------------------------------- not exactly YES
for typed in '' y Y yes Yes 'YES ' ' YES' YESS 'yes please' no; do
  reset_knobs; S_ANSWER="$typed"
  run "no-yes"
  expect "answer '$typed': cancelled, nothing changed" no_changes
  expect "answer '$typed': says Cancelled" has_out "Cancelled. Nothing was changed."
  expect "answer '$typed': installer does not continue" no_out "RETURNED"
  expect "answer '$typed': non-zero exit" test "$RC" -ne 0
done

# ---------------------------------------------------------------- no terminal
reset_knobs; S_TTY=0
run no-tty
expect "no terminal: nothing changed" no_changes
expect "no terminal: user is never asked" no_call 'prompt-read'
expect "no terminal: tells the user to use an interactive session" has_out "interactive"
expect "no terminal: non-zero exit" test "$RC" -ne 0
if command -v setsid >/dev/null 2>&1; then
  # shellcheck disable=SC2016
  if setsid -w bash -c '. "$1"; kfix_have_tty' _ "$TMP/block.sh" < /dev/null > /dev/null 2>&1; then
    bad "real kfix_have_tty must fail without a controlling terminal"
  else
    ok "real kfix_have_tty fails without a controlling terminal"
  fi
fi

# ---------------------------------------------------------------- YES: happy path
reset_knobs
run yes-happy
expect "YES: the red warning says it CANNOT BE UNDONE" has_out "THIS CANNOT BE UNDONE"
expect "YES: the warning names the cloud kernel removal" has_out "THE CLOUD KERNEL WILL BE REMOVED"
expect "YES: the warning says SSH will be lost" has_out "YOU WILL LOSE SSH ACCESS"
expect "YES: the warning says to check console access" has_out "CONSOLE ACCESS"
expect "YES: the warning says to take a snapshot" has_out "TAKE A SNAPSHOT FIRST"
expect "YES: asks for YES exactly" has_out "Type YES (capital letters, exactly)"
warn_line="$(grep -n 'CANNOT BE UNDONE' "$D/out" | head -n 1 | cut -d: -f1)"
expect "YES: nothing was changed before the answer was read" test "$(line_of 'prompt-read')" -lt "$(line_of '^apt-get')"
expect "YES: warning printed before the prompt" test -n "$warn_line"
install_l="$(line_of '^apt-get install')"; remove_l="$(line_of '^apt-get remove')"
grub_l="$(line_of '^update-grub')"; reboot_l="$(line_of '^reboot')"
expect "YES: installs linux-image-amd64" has_call '^apt-get install -y linux-image-amd64$'
expect "YES: order is install, remove, update-grub, reboot" test "$install_l" -lt "$remove_l" -a "$remove_l" -lt "$grub_l" -a "$grub_l" -lt "$reboot_l"
expect "YES: removes the versioned cloud kernel" has_call_f "linux-image-$CLOUD_VER"
expect "YES: removal goes through apt-get remove -y" has_call '^apt-get remove -y '
expect "YES: stock kernel is not in the removal list" no_call "^apt-get remove.*linux-image-6.12.48.deb13-amd64"
expect "YES: removes the cloud meta package too" has_call '^apt-get remove -y .*linux-image-cloud-amd64'
expect "YES: reboots exactly once" test "$(grep -c '^reboot$' "$D/calls")" -eq 1
countdown="$(grep -o 'Rebooting in [0-9]' "$D/out" | tr -d 'A-Za-z ' | tr '\n' '-')"
expect "YES: countdown is 5-4-3-2-1" test "$countdown" = "5-4-3-2-1-"
expect "YES: sleeps 5 times (one per count)" test "$(grep -c '^sleep 1$' "$D/calls")" -eq 5
expect "YES: tells the user to re-run the installer after the reboot" has_out "RE-RUN THIS"
expect "YES: installation does NOT continue after the reboot call" no_out "RETURNED"
expect "YES: exit status 0 after scheduling the reboot" test "$RC" -eq 0
expect "YES: marker records the boot id" grep -qx 'boot_id=boot-1' "$D/state/kernel-fix"
expect "YES: cloud kernel files are gone" test -z "$(ls "$D"/boot/*cloud* 2>/dev/null)"

# ---------------------------------------------------------------- re-run after the reboot: no loop
# Same fake system, now "after the reboot": new boot id, the stock kernel is running, PPP works.
S_KERNEL="$NEW_VER"; S_PPP_OK=1; S_BOOT_ID=boot-2; S_CFG=none
: > "$D/calls"
run yes-happy keep
expect "re-run after reboot: PPP passes and the real install starts" has_out "RETURNED"
expect "re-run after reboot: no apt, grub or reboot call (no loop)" test ! -s "$D/calls"
expect "re-run after reboot: marker is cleaned up" test ! -f "$D/state/kernel-fix"
expect "re-run after reboot: user is not asked again" no_call 'prompt-read'
expect "re-run after reboot: exit status 0" test "$RC" -eq 0

# ---------------------------------------------------------------- re-run, STILL a cloud kernel
reset_knobs; S_MARKER_BOOT="boot-1"; S_BOOT_ID="boot-2"
run still-cloud
expect "still cloud after reboot: aborts with 'this VPS cannot run L2TP'" has_out "this VPS cannot run L2TP"
expect "still cloud after reboot: nothing changed" no_changes
expect "still cloud after reboot: user is not asked again" no_call 'prompt-read'
expect "still cloud after reboot: no apt call at all" no_call '^apt-get'
expect "still cloud after reboot: marker kept, so it never offers the fix again" test -f "$D/state/kernel-fix"
expect "still cloud after reboot: installer does not continue" no_out "RETURNED"
expect "still cloud after reboot: non-zero exit" test "$RC" -ne 0
S_BOOT_ID="boot-3"
run still-cloud keep
expect "still cloud, third run: aborts the same way (no loop)" has_out "this VPS cannot run L2TP"

# ---------------------------------------------------------------- fix applied, reboot not done yet
reset_knobs; S_MARKER_BOOT="boot-1"; S_BOOT_ID="boot-1"
run not-rebooted
expect "not rebooted yet: says to reboot" has_out "has not been"
expect "not rebooted yet: does not say the VPS cannot run L2TP" no_out "this VPS cannot run L2TP"
expect "not rebooted yet: nothing changed" no_changes
expect "not rebooted yet: non-zero exit" test "$RC" -ne 0

# ---------------------------------------------------------------- safety: stop before removing anything
reset_knobs; S_INSTALL_FAIL=1
run install-fails
expect "install fails: cloud kernel NOT removed" no_call '^apt-get remove'
expect "install fails: no grub, no reboot" not_applied
expect "install fails: no marker" no_new_marker
expect "install fails: non-zero exit" test "$RC" -ne 0

reset_knobs; S_STOCK_NO_PPP=1
run stock-no-ppp
expect "new kernel without PPP: cloud kernel NOT removed" no_call '^apt-get remove'
expect "new kernel without PPP: no grub, no reboot" not_applied
expect "new kernel without PPP: no marker" no_new_marker
expect "new kernel without PPP: non-zero exit" test "$RC" -ne 0

reset_knobs; S_REMOVE_FAIL=1
run remove-fails
expect "remove fails: no grub, no reboot" no_call '^update-grub|^reboot' 
expect "remove fails: no marker" no_new_marker
expect "remove fails: tells the user not to reboot" has_out "Do NOT reboot"
expect "remove fails: non-zero exit" test "$RC" -ne 0

reset_knobs; S_GRUB_FAIL=1
run grub-fails
expect "update-grub fails: no reboot" no_call '^reboot'
expect "update-grub fails: no marker" no_new_marker
expect "update-grub fails: non-zero exit" test "$RC" -ne 0

reset_knobs; S_GRUB_EMPTY=1
run grub-without-new-kernel
expect "grub.cfg without the new kernel: no reboot" no_call '^reboot'
expect "grub.cfg without the new kernel: no marker" no_new_marker
expect "grub.cfg without the new kernel: non-zero exit" test "$RC" -ne 0

# ---------------------------------------------------------------- cases that must NOT offer the fix
reset_knobs; S_KERNEL="$STOCK_VER"
run stock-no-ppp-config
expect "stock kernel without PPP: no prompt, nothing changed" no_changes
expect "stock kernel without PPP: no prompt" no_call 'prompt-read'
expect "stock kernel without PPP: manual message" has_out "install a PPP-enabled kernel"
expect "stock kernel without PPP: non-zero exit" test "$RC" -ne 0

reset_knobs; S_CFG=on
run cloud-with-ppp-config
expect "cloud kernel that has PPP (module just failed): no kernel swap offered" no_call 'prompt-read'
expect "cloud kernel that has PPP: nothing changed" no_changes
expect "cloud kernel that has PPP: generic PPP error" has_out "PPP is not usable"
expect "cloud kernel that has PPP: non-zero exit" test "$RC" -ne 0

reset_knobs; S_ARCH=arm64
run other-arch
expect "non-amd64: no prompt, nothing changed" no_changes
expect "non-amd64: no prompt" no_call 'prompt-read'
expect "non-amd64: manual message" has_out "install a PPP-enabled kernel"

reset_knobs; S_NO_GRUB=1
run no-grub
expect "no update-grub on the system: no prompt, nothing changed" no_changes
expect "no update-grub on the system: manual message" has_out "install a PPP-enabled kernel"

# ---------------------------------------------------------------- ordering inside install.sh
inst="$ROOT/install.sh"
ensure_line="$(grep -n '^ensure_ppp$' "$inst" | head -n 1 | cut -d: -f1)"
base_apt_line="$(grep -n '^apt-get update -qq' "$inst" | head -n 1 | cut -d: -f1)"
stop_line="$(grep -n '^systemctl stop' "$inst" | head -n 1 | cut -d: -f1)"
backup_line="$(grep -n '^BACKUP_DIR=' "$inst" | head -n 1 | cut -d: -f1)"
expect "install.sh: ensure_ppp is called" test -n "$ensure_line"
expect "install.sh: PPP check runs before the first apt-get" test "$ensure_line" -lt "$base_apt_line"
expect "install.sh: PPP check runs before backups" test "$ensure_line" -lt "$backup_line"
expect "install.sh: PPP check runs before services are stopped" test "$ensure_line" -lt "$stop_line"
before="$(awk -v n="$ensure_line" '/^# BEGIN kernel-fix$/ {skip=1} NR < n && !skip {print} /^# END kernel-fix$/ {skip=0}' "$inst" | grep -vE '^[[:space:]]*#' | grep -E 'apt-get|systemctl|openssl|curl|mkdir|cat >' || true)"
expect "install.sh: nothing but the root and OS checks runs before the PPP check" test -z "$before"

exit "$fail"
