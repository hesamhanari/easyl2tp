#!/bin/bash
# easyl2tp — one-line installer for an L2TP + IKEv2 VPN server
# with a terminal panel, for Debian 13.
#
# Based on a tested, working Gemini-generated L2TP/IKEv2 script.
# Differences from that original, on purpose:
#  - NO hardcoded passwords or PSKs. Secrets are generated here
#    with openssl rand, unless you pass them in the environment
#    (see below), or unless a previous install already has them —
#    in which case the existing values are REUSED, so re-running
#    this installer does not break existing users.
#  - PPP is checked FIRST, before any service is stopped, any
#    package is installed or any config is overwritten. If this
#    kernel cannot do PPP, the installer does not install a server
#    that can never connect. On a Debian cloud kernel (PPP disabled
#    entirely) it offers to swap in the stock kernel, but only after
#    a big red warning and an exact "YES" typed by you; then it
#    reboots and you re-run the installer. See kernel-fix below.
#  - Existing configs are backed up to /root/easyl2tp-backup-*
#    before they are overwritten.
#  - Reviewed against SPEC.md (PR 1): the IKEv1 aggressive-mode PSK
#    flag is gone, xl2tpd requires PPP authentication itself, the
#    firewall no longer flips the global FORWARD policy or opens the
#    whole server to VPN clients, and secrets are no longer printed
#    at the end of the install.
#
# Usage (after this repo is public, or from a local copy):
#   bash <(curl -fsSL https://raw.githubusercontent.com/hesamhanari/easyl2tp/main/install.sh)
#   # or, from a cloned copy:
#   chmod +x install.sh && ./install.sh
#
# While the repo is private, the raw URL above needs auth.
# In that case clone the repo (private, needs GitHub auth) and
# run ./install.sh from the checkout, or copy install.sh to the
# server and run it there.
#
# Optional environment overrides (use them only to rotate a secret
# on purpose — changing them breaks existing clients until they
# update their settings):
#   TUNPW="..."       modem tunnel password (default: generated/reused)
#   IPSEC_PSK="..."   shared IPsec PSK      (default: generated/reused)
#   EASYL2TP_BRANCH="main"   branch to fetch ezl2tp from, if needed
#
# What it installs (same tested stack as the original):
#   strongswan-starter + /etc/ipsec.conf:
#     conn l2tp-psk  (IKEv1, transport, L2TP, 10.99.0.0/24)
#     conn ikev2-psk (IKEv2, 10.99.1.0/24)
#   xl2tpd (LNS 10.99.0.1, clients 10.99.0.10-250)
#   firewall/NAT via /usr/local/sbin/l2tp-fw.sh + l2tp-firewall.service
#   usage tracking: /var/log/vpn-usage/*, /usr/local/sbin/vpn-acct-update
#   admin CLI: /usr/local/bin/l2tp-user
#   panel: /usr/local/bin/ezl2tp (if it can be found next to
#     this script or fetched from the repo; non-fatal if missing)
#
# This installer does NOT offer PPTP. PPTP encryption is broken.
# L2TP/IPsec uses a shared PSK by design for L2TP clients;
# IKEv2 can use a per-user PSK (the user's PPP password).
#
set -u
umask 077

die() { echo "ERROR: $*" >&2; exit 1; }

if [ "$(id -u)" != "0" ]; then
  die "Run as root"
fi

# --- OS check: tested on Debian 13 only ---
if [ -f /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  if [ "${ID:-}" != "debian" ]; then
    die "This installer is tested on Debian 13 only (found ID=${ID:-unknown})."
  fi
  if [ "${VERSION_ID:-}" != "13" ]; then
    die "This installer is tested on Debian 13 only (found Debian ${VERSION_ID:-unknown})."
  fi
else
  die "Cannot detect the OS (/etc/os-release missing)."
fi

# --- PPP kernel check: the FIRST real step, before anything else ---
# pppd needs /dev/ppp, which needs the ppp_generic driver.
# On kernels where PPP is disabled in the config (Debian cloud
# kernels), no modprobe or mknod can fix it — only a PPP-enabled
# kernel can. Installing the VPN on such a kernel would leave a
# server that accepts L2TP tunnels and then kills every PPP session.
#
# Nothing below (apt, services, configs) runs before this passes.
# On a cloud kernel the installer can swap in the stock kernel, but
# only after a warning and an exact "YES"; see kernel_fix.
#
# BEGIN kernel-fix
# tests/kernel-fix-test.sh extracts everything between BEGIN and END
# and runs it against stubbed apt/dpkg/grub/reboot. Keep this block
# self-contained: variables and functions only, no top-level actions.
KFIX_STATE_DIR="/var/lib/easyl2tp"
KFIX_STATE_FILE="$KFIX_STATE_DIR/kernel-fix"
KFIX_BOOT_ID_FILE="/proc/sys/kernel/random/boot_id"
KFIX_BOOT_DIR="/boot"
KFIX_GRUB_CFG="/boot/grub/grub.cfg"
KFIX_MODULES_DIR="/lib/modules"

ppp_ready() {
  modprobe ppp_generic 2>/dev/null && modprobe ppp_async 2>/dev/null \
    && modprobe l2tp_ppp 2>/dev/null || return 1
  # /dev/ppp appears via udev/devtmpfs once ppp_generic is loaded.
  # Wait briefly, then prove it can really be opened.
  for _ in 1 2 3 4 5; do
    [ -c /dev/ppp ] && break
    sleep 1
  done
  [ -c /dev/ppp ] || return 1
  { exec 9<>/dev/ppp; } 2>/dev/null || return 1
  exec 9>&-
}

# Changes every boot; lets a re-run tell "not rebooted yet" from "rebooted
# and still the same kernel".
kfix_boot_id() { cat "$KFIX_BOOT_ID_FILE" 2>/dev/null || echo unknown; }

kfix_is_cloud_kernel() {
  case "$(uname -r)" in
    *-cloud-amd64) return 0 ;;
  esac
  return 1
}

# True only when the running kernel has no PPP at all (not just a module
# that failed to load).
kfix_kernel_lacks_ppp() {
  local cfg
  cfg="$KFIX_BOOT_DIR/config-$(uname -r)"
  if [ -f "$cfg" ]; then
    grep -q '^# CONFIG_PPP is not set' "$cfg"
    return
  fi
  ! find "$KFIX_MODULES_DIR/$(uname -r)" -name 'ppp_generic.ko*' 2>/dev/null | grep -q .
}

# Names of installed packages (dpkg status "i...") matching the given globs.
kfix_installed_pkgs() {
  # shellcheck disable=SC2016
  dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' "$@" 2>/dev/null \
    | awk '$1 ~ /^i/ { print $2 }'
}

# The meta package plus every versioned cloud kernel image.
kfix_cloud_pkgs() {
  kfix_installed_pkgs 'linux-image-cloud-amd64' 'linux-image-*-cloud-amd64'
}

# Versions (as in uname -r) of installed stock amd64 kernels, oldest first.
kfix_stock_versions() {
  kfix_installed_pkgs 'linux-image-[0-9]*-amd64' \
    | sed 's/^linux-image-//' \
    | grep -Ev -- '-(cloud|rt)-amd64$' \
    | sort -V
}

kfix_have_tty() { { : < /dev/tty; } 2>/dev/null; }

# Read the answer from the terminal, never from stdin: stdin can be the
# script itself (curl ... | bash).
kfix_read_answer() {
  local ans=""
  IFS= read -r ans < /dev/tty || ans=""
  printf '%s' "$ans"
}

kfix_red() {
  if [ -t 1 ]; then printf '\033[1;31m%s\033[0m\n' "$1"; else printf '%s\n' "$1"; fi
}

kfix_manual_message() {
  cat >&2 <<'PPPMSG'
PPP is DISABLED in the running kernel (CONFIG_PPP is not set).
No package, mknod, or modprobe can fix it on this kernel, and this
installer cannot swap the kernel on this system by itself.
Fix: install a PPP-enabled kernel, for example
  apt-get install -y linux-image-amd64
then make that kernel the boot default (check grub.cfg order —
cloud kernels are often listed first), reboot, and verify
  uname -r
no longer ends in -cloud-amd64 and that
  modprobe ppp_generic
succeeds. Only then re-run this installer.
PPPMSG
}

# The kernel swap. Only reached on a cloud kernel without PPP. Read-only
# checks first; nothing is changed until the user types exactly YES.
kernel_fix() {
  local cur new_ver ans i
  local -a cloud_pkgs
  cur="$(uname -r)"

  if [ "$(dpkg --print-architecture 2>/dev/null)" != "amd64" ] || ! command -v update-grub >/dev/null 2>&1; then
    kfix_manual_message
    exit 1
  fi
  if ! kfix_have_tty; then
    echo "ERROR: PPP is disabled in this cloud kernel ($cur), and the fix needs you to" >&2
    echo "confirm it at a terminal. Nothing was changed. Run the installer from an" >&2
    echo "interactive SSH session (not piped into bash, not from cron) and answer there." >&2
    exit 1
  fi

  echo
  echo "PPP is DISABLED in the running kernel ($cur)."
  echo "This is a Debian cloud kernel. No package, mknod or modprobe can fix that."
  echo "The fix is to replace it with the stock Debian kernel (linux-image-amd64)."
  echo
  echo "If you continue, this installer will, in this order:"
  echo "  1. install linux-image-amd64 (the stock Debian kernel)"
  echo "  2. REMOVE the cloud kernel(s): linux-image-*-cloud-amd64"
  echo "  3. run update-grub"
  echo "  4. reboot this server (5-second countdown)"
  echo
  kfix_red "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  kfix_red "WARNING: THIS CANNOT BE UNDONE."
  kfix_red "THE CLOUD KERNEL WILL BE REMOVED FROM THIS SERVER."
  kfix_red "IF THE STOCK KERNEL FAILS TO BOOT, YOU WILL LOSE SSH ACCESS."
  kfix_red "CHECK THAT YOUR PROVIDER GIVES YOU CONSOLE ACCESS (VNC, SERIAL OR RESCUE)"
  kfix_red "BEFORE YOU CONTINUE, AND TAKE A SNAPSHOT FIRST IF THIS IS A REAL SERVER."
  kfix_red "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo
  printf 'Type YES (capital letters, exactly) to continue. Anything else cancels and changes nothing: '
  ans="$(kfix_read_answer)"
  echo
  if [ "$ans" != "YES" ]; then
    echo "Cancelled. Nothing was changed."
    exit 1
  fi

  echo "Installing the stock Debian kernel (linux-image-amd64)..."
  apt-get update || echo "WARNING: apt-get update reported errors; continuing."
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y linux-image-amd64; then
    echo "ERROR: could not install linux-image-amd64. The cloud kernel was NOT removed" >&2
    echo "and nothing else was changed. Fix the apt error above and re-run." >&2
    exit 1
  fi

  # Prove the new kernel is really there, and has PPP, BEFORE the cloud
  # kernel is removed. If this fails the machine is still bootable as before.
  new_ver="$(kfix_stock_versions | tail -n 1)"
  if [ -z "$new_ver" ] \
    || [ ! -e "$KFIX_BOOT_DIR/vmlinuz-$new_ver" ] \
    || [ ! -e "$KFIX_BOOT_DIR/initrd.img-$new_ver" ] \
    || ! grep -Eq '^CONFIG_PPP=[ym]' "$KFIX_BOOT_DIR/config-$new_ver" 2>/dev/null; then
    echo "ERROR: the stock kernel did not install cleanly (no usable PPP-enabled kernel" >&2
    echo "found in $KFIX_BOOT_DIR). The cloud kernel was NOT removed. Look at the apt output" >&2
    echo "above, fix it, and re-run." >&2
    exit 1
  fi
  echo "Stock kernel ready: $new_ver"

  mapfile -t cloud_pkgs < <(kfix_cloud_pkgs)
  if [ "${#cloud_pkgs[@]}" -gt 0 ]; then
    echo "Removing the cloud kernel: ${cloud_pkgs[*]}"
    # With DEBIAN_FRONTEND=noninteractive Debian's prerm lets the running
    # kernel be removed without a prompt (we reboot right after).
    if ! DEBIAN_FRONTEND=noninteractive apt-get remove -y "${cloud_pkgs[@]}"; then
      echo "ERROR: could not remove the cloud kernel. Do NOT reboot yet." >&2
      echo "Remove it by hand, then run update-grub and reboot:" >&2
      echo "  apt-get remove ${cloud_pkgs[*]}" >&2
      exit 1
    fi
  fi
  if [ -n "$(kfix_cloud_pkgs)" ]; then
    echo "ERROR: a cloud kernel package is still installed. Do NOT reboot yet." >&2
    echo "Remove it by hand, then run update-grub and reboot." >&2
    exit 1
  fi

  echo "Updating GRUB..."
  if ! update-grub; then
    echo "ERROR: update-grub failed. Do NOT reboot until it succeeds:" >&2
    echo "  update-grub" >&2
    exit 1
  fi
  if ! grep -qF "vmlinuz-$new_ver" "$KFIX_GRUB_CFG" 2>/dev/null; then
    echo "ERROR: $KFIX_GRUB_CFG does not list the new kernel ($new_ver). Do NOT reboot" >&2
    echo "until GRUB is fixed (run update-grub and check the file)." >&2
    exit 1
  fi

  # Remember that the fix ran, so a re-run can tell "now fixed" from "still
  # a cloud kernel" and never loops through the fix again.
  if ! { mkdir -p "$KFIX_STATE_DIR" \
    && printf 'boot_id=%s\nfrom_kernel=%s\nto_kernel=%s\n' "$(kfix_boot_id)" "$cur" "$new_ver" > "$KFIX_STATE_FILE"; }; then
    echo "ERROR: could not write $KFIX_STATE_FILE. Reboot by hand when ready." >&2
    exit 1
  fi

  echo
  echo "Kernel fix done. The installation itself has NOT started yet."
  echo "AFTER THE REBOOT: wait about a minute, log in by SSH again, and RE-RUN THIS"
  echo "INSTALLER (the same command you used to start it)."
  echo
  i=5
  while [ "$i" -ge 1 ]; do
    echo "Rebooting in $i..."
    sleep 1
    i=$((i - 1))
  done
  echo "Rebooting now."
  if ! reboot; then
    echo "ERROR: the reboot command failed. Reboot by hand, then re-run the installer." >&2
    exit 1
  fi
  exit 0
}

# Returns 0 only when PPP works on the running kernel. Every other path
# either exits or hands over to kernel_fix. It never loops: a second
# visit after the fix aborts instead of offering the fix again.
ensure_ppp() {
  local state_boot_id
  echo "Checking PPP kernel support..."
  if ppp_ready; then
    if [ -f "$KFIX_STATE_FILE" ]; then
      rm -f "$KFIX_STATE_FILE"
      echo "Kernel fix from the earlier run worked: now running $(uname -r)."
    fi
    echo "PPP kernel support: OK (kernel $(uname -r))"
    return 0
  fi

  if [ -f "$KFIX_STATE_FILE" ]; then
    state_boot_id="$(awk -F= '$1 == "boot_id" { print $2; exit }' "$KFIX_STATE_FILE" 2>/dev/null)"
    if [ "$state_boot_id" = "$(kfix_boot_id)" ]; then
      echo "ERROR: the kernel fix was already applied, but this server has not been" >&2
      echo "rebooted since (still running $(uname -r)). Reboot it:  reboot" >&2
      echo "then log in again and re-run this installer." >&2
      exit 1
    fi
    if kfix_is_cloud_kernel; then
      echo "ERROR: this VPS cannot run L2TP." >&2
      echo "The stock kernel was installed and the server was rebooted, but it came back" >&2
      echo "on a cloud kernel ($(uname -r)) without PPP. The provider is booting its own" >&2
      echo "kernel instead of the one in /boot (look for a kernel / boot setting in the" >&2
      echo "provider's control panel), or this VPS type cannot use a custom kernel." >&2
      echo "Use a different VPS image/plan. Not trying again, to avoid a reboot loop." >&2
      echo "(To allow one more attempt on purpose, delete $KFIX_STATE_FILE.)" >&2
      exit 1
    fi
  fi

  if kfix_is_cloud_kernel && kfix_kernel_lacks_ppp; then
    kernel_fix # always exits: reboot on success, an error otherwise
  fi

  if grep -q '^# CONFIG_PPP is not set' "$KFIX_BOOT_DIR/config-$(uname -r)" 2>/dev/null; then
    kfix_manual_message
  else
    echo "ERROR: PPP is not usable on kernel $(uname -r):" >&2
    echo "the modules ppp_generic, ppp_async, l2tp_ppp did not all load," >&2
    echo "or /dev/ppp cannot be opened. Check 'ls /lib/modules/'," >&2
    echo "'modprobe ppp_generic' and the kernel config, then re-run." >&2
  fi
  exit 1
}
# END kernel-fix

ensure_ppp
printf 'ppp_generic\nppp_async\nl2tp_ppp\n' > /etc/modules-load.d/l2tp.conf

# Minimal tools: openssl for secret generation and curl for the server-IP
# lookup. Only now, after the PPP check has passed.
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y openssl curl >/dev/null 2>&1 || true
command -v openssl >/dev/null 2>&1 || die "openssl is required but could not be installed."
command -v curl >/dev/null 2>&1 || die "curl is required but could not be installed."

# --- Secrets: env override > existing install > generated ---
# Reusing existing values on re-install is what keeps existing
# modem/phone users working. Generating only when missing is
# what keeps a fresh install from having any default password.
EXISTING_TUNPW="$(awk '{print $3; exit}' /etc/xl2tpd/l2tp-secrets 2>/dev/null || true)"
EXISTING_MASTER_PSK="$(awk -F'"' '/^: PSK/ {print $2; exit}' /etc/ipsec.secrets 2>/dev/null || true)"

# Secrets go into config files inside double quotes, so keep them to a
# safe alphabet (generated ones are hex).
valid_secret() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._-]{8,64}$'; }

if [ -n "${TUNPW:-}" ]; then
  valid_secret "$TUNPW" || die "TUNPW must be 8-64 characters of A-Z a-z 0-9 . _ - only."
elif [ -n "$EXISTING_TUNPW" ]; then
  TUNPW="$EXISTING_TUNPW"
  echo "Reusing existing tunnel password (not changing it, so existing modems keep working)."
else
  TUNPW="$(openssl rand -hex 8)"
fi

if [ -n "${IPSEC_PSK:-}" ]; then
  valid_secret "$IPSEC_PSK" || die "IPSEC_PSK must be 8-64 characters of A-Z a-z 0-9 . _ - only."
elif [ -n "$EXISTING_MASTER_PSK" ]; then
  IPSEC_PSK="$EXISTING_MASTER_PSK"
  echo "Reusing existing master IPsec PSK (not changing it, so existing clients keep working)."
else
  IPSEC_PSK="$(openssl rand -hex 16)"
fi

# --- Server IP (public IPv4, checked before anything destructive) ---
SERVER_IP=""
for url in https://api.ipify.org https://ifconfig.me; do
  cand="$(curl -4 -fsS --max-time 10 "$url" 2>/dev/null || true)"
  if printf '%s' "$cand" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
    SERVER_IP="$cand"
    break
  fi
done
[ -n "$SERVER_IP" ] || die "Could not detect the server's public IPv4 address. Check outbound internet, then re-run."
echo "Server IP: $SERVER_IP"

# UDP 1701 must be free or already ours (xl2tpd from a previous install).
# Checked here, BEFORE any service is stopped, so a refusal changes nothing.
PORT_OWNER="$(ss -ulnpH 2>/dev/null | awk '$4 ~ /:1701$/' || true)"
if [ -n "$PORT_OWNER" ] && ! printf '%s' "$PORT_OWNER" | grep -q 'xl2tpd'; then
  die "UDP 1701 is already in use by another process:
$PORT_OWNER"
fi

# --- Backups, before overwriting anything ---
BACKUP_DIR="/root/easyl2tp-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
backup_file() {
  if [ -f "$1" ]; then
    cp -a "$1" "$BACKUP_DIR/" 2>/dev/null || true
    echo "Backed up $1 to $BACKUP_DIR"
  fi
}
backup_file /etc/ipsec.conf
backup_file /etc/ipsec.secrets
backup_file /etc/xl2tpd/xl2tpd.conf
backup_file /etc/xl2tpd/l2tp-secrets
backup_file /etc/ppp/options.xl2tpd
backup_file /etc/ppp/chap-secrets
backup_file /etc/ppp/pap-secrets
backup_file /etc/strongswan.conf
backup_file /etc/sysctl.d/99-l2tp.conf

# --- From here on, this is the tested original script, unchanged
# in behaviour except for the secret handling above and the
# early PPP check. The two settings SPEC.md flagged were reviewed:
#  - strongswan.conf: the "aggressive mode PSK" flag was removed.
#    Aggressive mode only applies to a conn with aggressive=yes,
#    and no conn here sets it, so it only added attack surface.
#  - xl2tpd.conf: "require authentication" is now yes. In xl2tpd
#    this is PPP-level (it adds "auth" to pppd), NOT the L2TP
#    tunnel password (that is "challenge", left off on purpose so
#    phones without a tunnel secret keep working).
systemctl stop xl2tpd strongswan strongswan-starter strongswan-swanctl l2tp-firewall 2>/dev/null || true

DEBIAN_FRONTEND=noninteractive apt-get install -y \
  xl2tpd ppp iptables conntrack curl openssl tcpdump gawk \
  strongswan strongswan-starter strongswan-charon strongswan-pki \
  libstrongswan libstrongswan-standard-plugins libstrongswan-extra-plugins \
  libcharon-extra-plugins libcharon-extauth-plugins || die "apt-get install failed; nothing else was changed after this point. Fix the apt error and re-run."

modprobe -a ppp_generic ppp_async l2tp_ppp 2>/dev/null || true

rm -f /usr/local/sbin/ipsec /usr/local/libexec/ipsec/* 2>/dev/null || true
hash -r

DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -o Dpkg::Options::="--force-confmiss" -y \
  strongswan strongswan-starter strongswan-charon strongswan-pki \
  libstrongswan libstrongswan-standard-plugins libstrongswan-extra-plugins \
  libcharon-extra-plugins libcharon-extauth-plugins >/dev/null

cat > /etc/strongswan.conf <<'SWAN'
charon {
  load_modular = no
  install_routes = no
  plugins {
    include strongswan.d/charon/*.conf
    updown {
      load = yes
    }
    kernel-netlink {
      install_routes = no
    }
  }
}
SWAN

if command -v aa-complain >/dev/null 2>&1; then
  aa-complain /usr/lib/ipsec/charon 2>/dev/null || true
fi
ln -sf /etc/apparmor.d/usr.lib.ipsec.charon /etc/apparmor.d/disable/ 2>/dev/null || true
if command -v apparmor_parser >/dev/null 2>&1; then
  apparmor_parser -R /etc/apparmor.d/usr.lib.ipsec.charon 2>/dev/null || true
fi

mkdir -p /var/log/vpn-usage /run/vpn-sessions
touch /var/log/vpn-usage/totals.db /var/log/vpn-usage/sessions.log
chmod 600 /var/log/vpn-usage/totals.db /var/log/vpn-usage/sessions.log

cat > /usr/local/sbin/vpn-acct-update <<'ACCT'
#!/bin/bash
USR="${1:-unknown}"
USR=$(echo "$USR" | tr -d '"' | awk '{print $1}')
RX="${2:-0}"
TX="${3:-0}"
PROTO="${4:-VPN}"
EVENT="${5:-DISCONNECT}"
DB="/var/log/vpn-usage/totals.db"
LOG="/var/log/vpn-usage/sessions.log"

[ -z "$USR" ] && exit 0
[[ ! "$RX" =~ ^[0-9]+$ ]] && RX=0
[[ ! "$TX" =~ ^[0-9]+$ ]] && TX=0

(
  flock -x 200
  touch "$DB"
  if [ "$EVENT" = "CONNECT" ]; then
    printf "%s | %-10s | %-8s | %-15s | Session started\n" "$(date '+%Y-%m-%d %H:%M:%S')" "CONNECT" "$PROTO" "$USR" >> "$LOG"
    exit 0
  fi

  if [ "$RX" -gt 0 ] || [ "$TX" -gt 0 ]; then
    awk -v u="$USR" -v r="$RX" -v t="$TX" '
    BEGIN { found=0 }
    $1 == u {
      $2 = $2 + r;
      $3 = $3 + t;
      found=1
    }
    { print $1, $2, $3 }
    END {
      if (!found) print u, r, t
    }
    ' "$DB" > "${DB}.tmp" && mv "${DB}.tmp" "$DB"
  fi

  printf "%s | %-10s | %-8s | %-15s | Up: %10s B | Down: %10s B\n" "$(date '+%Y-%m-%d %H:%M:%S')" "DISCONNECT" "$PROTO" "$USR" "$RX" "$TX" >> "$LOG"
) 200>/var/log/vpn-usage/.lock
ACCT
chmod +x /usr/local/sbin/vpn-acct-update

cat > /etc/xl2tpd/xl2tpd.conf <<CONF
[global]
port = 1701
auth file = /etc/xl2tpd/l2tp-secrets
access control = no
ipsec saref = no

[lns default]
ip range = 10.99.0.10-10.99.0.250
local ip = 10.99.0.1
require authentication = yes
challenge = no
length bit = yes
name = l2tpd
pppoptfile = /etc/ppp/options.xl2tpd
CONF

cat > /etc/ppp/options.xl2tpd <<CONF
name l2tpd
ipcp-accept-local
ipcp-accept-remote
ms-dns 1.1.1.1
ms-dns 8.8.8.8
noccp
nomppe
novj
novjccomp
nopcomp
noaccomp
auth
require-pap
require-chap
require-mschap-v2
mtu 1360
mru 1360
lcp-echo-interval 30
lcp-echo-failure 4
CONF

mkdir -p /etc/ppp/ip-up.d /etc/ppp/ip-down.d
cat > /etc/ppp/ip-up.d/99-l2tp-rpfilter <<'PPPFW'
#!/bin/bash
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
for f in /proc/sys/net/ipv4/conf/*/rp_filter; do
  echo 0 > "$f" 2>/dev/null || true
done
ip link set dev "$1" mtu 1360 2>/dev/null || true
while ip rule del to 10.99.0.0/24 lookup main priority 10 2>/dev/null; do :; done
ip rule add to 10.99.0.0/24 lookup main priority 10 2>/dev/null || true
ip route flush table 220 2>/dev/null || true

mkdir -p /run/vpn-sessions
USR=$(echo "${PEERNAME:-unknown}" | tr -d '"')
echo "$USR ${5:-unknown}" > "/run/vpn-sessions/$1"
/usr/local/sbin/vpn-acct-update "$USR" 0 0 "L2TP($1)" "CONNECT"
PPPFW
chmod +x /etc/ppp/ip-up.d/99-l2tp-rpfilter

cat > /etc/ppp/ip-down.d/99-l2tp-acct <<'PPPDOWN'
#!/bin/bash
USR="${PEERNAME:-}"
if [ -z "$USR" ] && [ -f "/run/vpn-sessions/$1" ]; then
  USR=$(awk '{print $1}' "/run/vpn-sessions/$1")
fi
rm -f "/run/vpn-sessions/$1"

RX="${BYTES_RCVD:-0}"
TX="${BYTES_SENT:-0}"
/usr/local/sbin/vpn-acct-update "$USR" "$RX" "$TX" "L2TP($1)" "DISCONNECT"
PPPDOWN
chmod +x /etc/ppp/ip-down.d/99-l2tp-acct

cat > /usr/local/sbin/ipsec-updown.sh <<'UPDOWN'
#!/bin/bash
USR=$(echo "${PLUTO_PEER_ID:-unknown}" | tr -d '"')
VIP="${PLUTO_PEER_SOURCEIP:-${PLUTO_PEER_CLIENT%/*}}"

case "${PLUTO_VERB:-}" in
  up-client|up-host)
    if [ -n "$VIP" ] && [ "$VIP" != "0.0.0.0" ]; then
      mkdir -p /run/vpn-sessions
      echo "$USR $VIP" > "/run/vpn-sessions/ikev2_${VIP}"
      while iptables -D FORWARD -s "$VIP" -m comment --comment "IKEV2_UP_${USR}" -j ACCEPT 2>/dev/null; do :; done
      while iptables -D FORWARD -d "$VIP" -m comment --comment "IKEV2_DOWN_${USR}" -j ACCEPT 2>/dev/null; do :; done
      iptables -I FORWARD 1 -s "$VIP" -m comment --comment "IKEV2_UP_${USR}" -j ACCEPT
      iptables -I FORWARD 1 -d "$VIP" -m comment --comment "IKEV2_DOWN_${USR}" -j ACCEPT
      /usr/local/sbin/vpn-acct-update "$USR" 0 0 "IKEv2($VIP)" "CONNECT"
    fi
    ;;
  down-client|down-host)
    RX="${PLUTO_BYTES_IN:-0}"
    TX="${PLUTO_BYTES_OUT:-0}"
    if [ -n "$VIP" ] && [ "$VIP" != "0.0.0.0" ]; then
      rm -f "/run/vpn-sessions/ikev2_${VIP}"
      IPT_RX=$(iptables -L FORWARD -v -n -x 2>/dev/null | awk -v ip="$VIP" '$8 == ip && /IKEV2_UP_/ {print $2; exit}')
      IPT_TX=$(iptables -L FORWARD -v -n -x 2>/dev/null | awk -v ip="$VIP" '$9 == ip && /IKEV2_DOWN_/ {print $2; exit}')
      [[ "${IPT_RX:-0}" -gt "$RX" ]] && RX="$IPT_RX"
      [[ "${IPT_TX:-0}" -gt "$TX" ]] && TX="$IPT_TX"
      while iptables -D FORWARD -s "$VIP" -m comment --comment "IKEV2_UP_${USR}" -j ACCEPT 2>/dev/null; do :; done
      while iptables -D FORWARD -d "$VIP" -m comment --comment "IKEV2_DOWN_${USR}" -j ACCEPT 2>/dev/null; do :; done
    fi
    /usr/local/sbin/vpn-acct-update "$USR" "${RX:-0}" "${TX:-0}" "IKEv2($VIP)" "DISCONNECT"
    ;;
esac
exit 0
UPDOWN
chmod +x /usr/local/sbin/ipsec-updown.sh

echo "* * $TUNPW" > /etc/xl2tpd/l2tp-secrets
touch /etc/ppp/chap-secrets /etc/ppp/pap-secrets
chmod 600 /etc/xl2tpd/l2tp-secrets /etc/ppp/chap-secrets /etc/ppp/pap-secrets

cat > /etc/ipsec.conf <<CONF
config setup
  uniqueids=no
  charondebug="ike 2, knl 1, cfg 2, net 1"

conn %default
  ikelifetime=60m
  keylife=20m
  rekeymargin=3m
  keyingtries=3
  dpddelay=30s
  dpdtimeout=120s
  dpdaction=clear

conn l2tp-psk
  auto=add
  keyexchange=ikev1
  authby=secret
  type=transport
  left=%defaultroute
  leftid=$SERVER_IP
  leftprotoport=17/1701
  right=%any
  rightid=%any
  rightprotoport=17/%any
  rekey=no

conn ikev2-psk
  auto=add
  keyexchange=ikev2
  authby=secret
  fragmentation=yes
  forceencaps=yes
  rekey=no
  left=%defaultroute
  leftid=%any
  leftsubnet=0.0.0.0/0
  leftupdown=/usr/local/sbin/ipsec-updown.sh
  right=%any
  rightid=%any
  rightsourceip=10.99.1.10-10.99.1.250
  rightdns=1.1.1.1,8.8.8.8
CONF

# Rebuild ipsec.secrets from existing users (preserved) + master PSK.
# Per-user lines let IKEv2 authenticate with the user's own password;
# the master lines let L2TP/IPsec clients use the shared PSK.
: > /etc/ipsec.secrets
awk '!/^#/ && NF>=3 {
  u=$1; gsub(/"/, "", u);
  p=$3; gsub(/"/, "", p);
  print "\"" u "\" : PSK \"" p "\""
  print "%any \"" u "\" : PSK \"" p "\""
}' /etc/ppp/chap-secrets >> /etc/ipsec.secrets 2>/dev/null || true

cat >> /etc/ipsec.secrets <<SEC
$SERVER_IP %any : PSK "$IPSEC_PSK"
%any %any : PSK "$IPSEC_PSK"
: PSK "$IPSEC_PSK"
SEC
chmod 600 /etc/ipsec.secrets

cat > /etc/sysctl.d/99-l2tp.conf <<'SYSCTL'
net.ipv4.ip_forward=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
SYSCTL
sysctl -q -p /etc/sysctl.d/99-l2tp.conf
for vpn in /proc/sys/net/ipv4/conf/*; do
  echo 0 > "$vpn/rp_filter" 2>/dev/null || true
done

cat > /usr/local/sbin/l2tp-fw.sh <<'FW'
#!/bin/bash
IF=$(ip -4 route show default | awk '/default/ {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')
S1=10.99.0.0/24
S2=10.99.1.0/24

add() {
  t=$1
  shift
  if ! iptables -t "$t" -C "$@" 2>/dev/null; then
    iptables -t "$t" -I "$@"
  fi
}

del() {
  t=$1
  shift
  while iptables -t "$t" -D "$@" 2>/dev/null; do :; done
}

case "$1" in
up)
  while ip rule del to $S1 lookup main priority 10 2>/dev/null; do :; done
  while ip rule del from $S1 lookup main priority 10 2>/dev/null; do :; done
  while ip rule del to $S2 lookup main priority 10 2>/dev/null; do :; done
  while ip rule del from $S2 lookup main priority 10 2>/dev/null; do :; done
  ip rule add to $S1 lookup main priority 10
  ip rule add from $S1 lookup main priority 10
  ip rule add to $S2 lookup main priority 10
  ip rule add from $S2 lookup main priority 10
  ip route replace $S2 dev "$IF" table main 2>/dev/null || true
  ip route flush table 220 2>/dev/null || true
  ip route flush cache 2>/dev/null || true

  ip xfrm policy delete dir in proto udp dport 1701 priority 1 2>/dev/null || true
  ip xfrm policy delete dir fwd proto udp dport 1701 priority 1 2>/dev/null || true
  ip xfrm policy delete dir out proto udp sport 1701 priority 1 2>/dev/null || true

  ip xfrm policy delete dir in src $S1 dst 0.0.0.0/0 priority 1 2>/dev/null || true
  ip xfrm policy delete dir fwd src $S1 dst 0.0.0.0/0 priority 1 2>/dev/null || true
  ip xfrm policy delete dir out src 0.0.0.0/0 dst $S1 priority 1 2>/dev/null || true

  ip xfrm policy add dir in src $S1 dst 0.0.0.0/0 priority 1 action allow 2>/dev/null || true
  ip xfrm policy add dir fwd src $S1 dst 0.0.0.0/0 priority 1 action allow 2>/dev/null || true
  ip xfrm policy add dir out src 0.0.0.0/0 dst $S1 priority 1 action allow 2>/dev/null || true

  # Older installs opened the whole server to VPN clients; drop that rule.
  del filter INPUT -i ppp+ -j ACCEPT

  add filter INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
  add filter INPUT -p udp -m multiport --dports 500,4500,1701 -j ACCEPT
  add filter INPUT -p esp -j ACCEPT
  add filter INPUT -i ppp+ -p icmp -j ACCEPT
  add filter FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
  add filter FORWARD -i ppp+ -j ACCEPT
  add filter FORWARD -o ppp+ -j ACCEPT
  add filter FORWARD -s $S1 -j ACCEPT
  add filter FORWARD -d $S1 -j ACCEPT
  add filter FORWARD -s $S2 -j ACCEPT
  add filter FORWARD -d $S2 -j ACCEPT

  if iptables -L ufw-before-forward >/dev/null 2>&1; then
    add filter ufw-before-forward -i ppp+ -j ACCEPT
    add filter ufw-before-forward -o ppp+ -j ACCEPT
    add filter ufw-before-forward -s $S1 -j ACCEPT
    add filter ufw-before-forward -d $S1 -j ACCEPT
    add filter ufw-before-forward -s $S2 -j ACCEPT
    add filter ufw-before-forward -d $S2 -j ACCEPT
  fi

  del nat POSTROUTING -s $S1 -m policy --dir out --pol ipsec -j ACCEPT
  del nat POSTROUTING -s $S2 -o "$IF" -m policy --dir out --pol ipsec -j ACCEPT
  del nat POSTROUTING -s $S2 -o "$IF" -j MASQUERADE
  del nat POSTROUTING -s $S1 -o "$IF" -j MASQUERADE

  add nat POSTROUTING -s $S2 -o "$IF" -j MASQUERADE
  add nat POSTROUTING -s $S2 -o "$IF" -m policy --dir out --pol ipsec -j ACCEPT
  add nat POSTROUTING -s $S1 -o "$IF" -j MASQUERADE

  add mangle FORWARD -s $S1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
  add mangle FORWARD -d $S1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
  add mangle FORWARD -s $S2 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
  add mangle FORWARD -d $S2 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

  conntrack -D -p udp --dport 1701 >/dev/null 2>&1 || true
  conntrack -D -p udp --dport 500 >/dev/null 2>&1 || true
  conntrack -D -p udp --dport 4500 >/dev/null 2>&1 || true
  ;;
down)
  while ip rule del to $S1 lookup main priority 10 2>/dev/null; do :; done
  while ip rule del from $S1 lookup main priority 10 2>/dev/null; do :; done
  while ip rule del to $S2 lookup main priority 10 2>/dev/null; do :; done
  while ip rule del from $S2 lookup main priority 10 2>/dev/null; do :; done
  ip route del $S2 dev "$IF" table main 2>/dev/null || true

  ip xfrm policy delete dir in src $S1 dst 0.0.0.0/0 priority 1 2>/dev/null || true
  ip xfrm policy delete dir fwd src $S1 dst 0.0.0.0/0 priority 1 2>/dev/null || true
  ip xfrm policy delete dir out src 0.0.0.0/0 dst $S1 priority 1 2>/dev/null || true

  del filter INPUT -p udp -m multiport --dports 500,4500,1701 -j ACCEPT
  del filter INPUT -p esp -j ACCEPT
  del filter INPUT -i ppp+ -p icmp -j ACCEPT
  del filter INPUT -i ppp+ -j ACCEPT
  del filter FORWARD -i ppp+ -j ACCEPT
  del filter FORWARD -o ppp+ -j ACCEPT
  del filter FORWARD -s $S1 -j ACCEPT
  del filter FORWARD -d $S1 -j ACCEPT
  del filter FORWARD -s $S2 -j ACCEPT
  del filter FORWARD -d $S2 -j ACCEPT

  del nat POSTROUTING -s $S2 -o "$IF" -m policy --dir out --pol ipsec -j ACCEPT
  del nat POSTROUTING -s $S2 -o "$IF" -j MASQUERADE
  del nat POSTROUTING -s $S1 -o "$IF" -j MASQUERADE

  del mangle FORWARD -s $S1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
  del mangle FORWARD -d $S1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
  del mangle FORWARD -s $S2 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
  del mangle FORWARD -d $S2 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
  ;;
esac
FW
chmod +x /usr/local/sbin/l2tp-fw.sh

cat > /etc/systemd/system/l2tp-firewall.service <<'UNIT'
[Unit]
Description=L2TP and IPsec firewall and NAT rules
After=network-online.target strongswan-starter.service
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/l2tp-fw.sh up
ExecStop=/usr/local/sbin/l2tp-fw.sh down
[Install]
WantedBy=multi-user.target
UNIT

cat > /usr/local/bin/l2tp-user <<'USER_SCRIPT'
#!/bin/bash
# easyl2tp-api: usage-v1
# ezl2tp looks for the line above before it runs "l2tp-user usage". A copy
# of l2tp-user without it would take "usage" for a new username.
set -eu

ACT="${1:-list}"
USR="${2:-}"
PAS="${3:-}"

if [ -n "$ACT" ] && [ "$ACT" != "add" ] && [ "$ACT" != "del" ] && [ "$ACT" != "list" ] && [ "$ACT" != "stats" ] && [ "$ACT" != "reset" ] && [ "$ACT" != "logs" ] && [ "$ACT" != "usage" ]; then
  PAS="${2:-}"
  USR="$ACT"
  ACT="add"
fi

# Names and passwords end up in chap-secrets, ipsec.secrets and sed
# patterns, so only a safe alphabet is accepted. Checked before anything
# else runs, so a bad name changes nothing.
if [ "$ACT" = "add" ] || [ "$ACT" = "del" ] || { [ "$ACT" = "reset" ] && [ -n "$USR" ]; }; then
  if ! printf '%s' "$USR" | grep -Eq '^[A-Za-z0-9._-]{1,32}$'; then
    echo "Invalid username: use 1-32 characters of A-Z a-z 0-9 . _ - (no spaces or quotes)." >&2
    exit 1
  fi
fi
if [ "$ACT" = "add" ] && [ -n "$PAS" ]; then
  if ! printf '%s' "$PAS" | grep -Eq '^[A-Za-z0-9._-]{6,64}$'; then
    echo "Invalid password: use 6-64 characters of A-Z a-z 0-9 . _ - (no spaces or quotes)." >&2
    exit 1
  fi
fi

# Where the live data comes from. Online status comes ONLY from the session
# files that the ppp and IPsec hooks write: pppN (L2TP) and ikev2_<VIP>.
CHAP="/etc/ppp/chap-secrets"
SESS_DIR="/run/vpn-sessions"
NET_DIR="/sys/class/net"
DB="/var/log/vpn-usage/totals.db"
touch "$DB"

SERVER_IP=""
MASTER_PSK=""
TUN_PASS=""
# Only the commands that print or rebuild secrets need these. stats, usage,
# logs and reset must work, and stay fast, without them.
load_server_info() {
  # The server IP is what the installer wrote into ipsec.conf (no network call).
  SERVER_IP=$(awk -F= '/^[[:space:]]*leftid=/ && $2 ~ /^[0-9]+(\.[0-9]+){3}$/ {print $2; exit}' /etc/ipsec.conf 2>/dev/null || true)
  [ -n "$SERVER_IP" ] || SERVER_IP=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo unknown)
  MASTER_PSK=$(awk -F'"' '/^: PSK/ {print $2; exit}' /etc/ipsec.secrets)
  TUN_PASS=$(awk '{print $3; exit}' /etc/xl2tpd/l2tp-secrets)
}
case "$ACT" in
  add | del | list) load_server_info ;;
esac

rebuild_ipsec_secrets() {
  : > /etc/ipsec.secrets
  awk '!/^#/ && NF>=3 {
    u=$1; gsub(/"/, "", u);
    p=$3; gsub(/"/, "", p);
    print "\"" u "\" : PSK \"" p "\""
    print "%any \"" u "\" : PSK \"" p "\""
  }' /etc/ppp/chap-secrets >> /etc/ipsec.secrets 2>/dev/null
  cat >> /etc/ipsec.secrets <<EOF
$SERVER_IP %any : PSK "$MASTER_PSK"
%any %any : PSK "$MASTER_PSK"
: PSK "$MASTER_PSK"
EOF
  chmod 600 /etc/ipsec.secrets
}

# One row per user:  <user> <upload_bytes> <download_bytes> <sessions>
#   bytes    = totals.db (sessions that already ended)
#              + live counters of the sessions that are open right now
#   sessions = IKEv2(<vip>) and L2TP(<pppN>), comma-separated, or "-" if offline
# This is the single place that decides who is online and how much they used,
# so stats, list, usage and the ezl2tp panel can never disagree.
#
# No double counting: totals.db is only written when a session ends, at the
# same moment its session file, ppp device and iptables rules go away, and
# live bytes are only read for sessions that still have a session file.
usage_rows() {
  local facts f dev u peer rx tx rc=0
  facts=$(mktemp)

  # T = bytes of finished sessions, U = every user, so offline users get a row.
  awk 'NF >= 3 && $1 != "" { print "T", $1, $2, $3 }' "$DB" >> "$facts" 2>/dev/null || true
  awk '!/^#/ && NF >= 3 { u = $1; gsub(/"/, "", u); if (u != "") print "U", u }' "$CHAP" >> "$facts" 2>/dev/null || true

  # F = session files: "pppN" (L2TP) or "ikev2_<VIP>" (IKEv2), content "<user> <peer>".
  if [ -d "$SESS_DIR" ]; then
    for f in "$SESS_DIR"/*; do
      [ -f "$f" ] || continue
      u=""
      peer=""
      read -r u peer < "$f" || true
      u=$(printf '%s' "$u" | tr -d '"')
      echo "F $(basename "$f") ${u:-unknown} ${peer:--}" >> "$facts"
    done
  fi

  # D = live counters of every ppp interface (L2TP). rx = from the client.
  for f in "$NET_DIR"/ppp*; do
    [ -e "$f" ] || continue
    dev=$(basename "$f")
    rx=$(cat "$f/statistics/rx_bytes" 2>/dev/null || echo 0)
    tx=$(cat "$f/statistics/tx_bytes" 2>/dev/null || echo 0)
    peer=$(ip -4 addr show dev "$dev" 2>/dev/null | awk '/peer/ { sub(/\/.*/, "", $4); print $4; exit }')
    echo "D $dev $rx $tx ${peer:--}" >> "$facts"
  done

  # S = IKEv2 child SAs as strongSwan reports them. The user is the id in
  # brackets after the "..." on the ESTABLISHED line; bytes_i = from the client.
  ipsec statusall 2>/dev/null | gawk '
    /ikev2-psk\[[0-9]+\]: ESTABLISHED/ {
      cur_user = ""
      if (match($0, /\.\.\.[^ ]+\[([^\]]+)\]/, m)) {
        cur_user = m[1]
        gsub(/"/, "", cur_user)
      }
    }
    /ikev2-psk\{[0-9]+\}:.*bytes_i/ {
      rx = 0; tx = 0
      if (match($0, /([0-9]+) bytes_i/, bi)) rx = bi[1]
      if (match($0, /([0-9]+) bytes_o/, bo)) tx = bo[1]
    }
    /ikev2-psk\{[0-9]+\}:.*=== 10\.99\.1\./ {
      if (match($0, /=== (10\.99\.1\.[0-9]+)/, vip)) {
        print "S", vip[1], (cur_user != "" ? cur_user : "-"), rx + 0, tx + 0
        rx = 0; tx = 0
      }
    }
  ' >> "$facts" || true

  # I = iptables FORWARD counters per VIP (IKEV2_UP_* = from the client,
  # IKEV2_DOWN_* = to the client). They keep counting across IKEv2 child SA
  # rekeys, which statusall does not. The top-most rule is the live one.
  iptables -w -nvxL FORWARD 2>/dev/null | awk '
    /IKEV2_UP_/ && $8 ~ /^10\.99\.1\.[0-9]+$/ { if (!($8 in up)) up[$8] = $2; seen[$8] = 1 }
    /IKEV2_DOWN_/ && $9 ~ /^10\.99\.1\.[0-9]+$/ { if (!($9 in down)) down[$9] = $2; seen[$9] = 1 }
    END { for (v in seen) print "I", v, (v in up ? up[v] : 0), (v in down ? down[v] : 0) }
  ' >> "$facts" || true

  awk '
    function max(a, b) { a += 0; b += 0; return (a > b) ? a : b }
    function addsess(user, label, rx, tx) {
      users[user] = 1
      r[user] += rx
      t[user] += tx
      st[user] = (st[user] == "" ? label : st[user] "," label)
    }
    $1 == "T" { users[$2] = 1; r[$2] += $3; t[$2] += $4 }
    $1 == "U" { users[$2] = 1 }
    $1 == "F" { nf++; fname[nf] = $2; fuser[nf] = $3; fpeer[nf] = $4 }
    $1 == "D" { hasdev[$2] = 1; drx[$2] = $3; dtx[$2] = $4; dpeer[$2] = $5 }
    $1 == "S" { ns++; svip[ns] = $2; suser[ns] = $3; srx[$2] = max(srx[$2], $4); stx[$2] = max(stx[$2], $5) }
    $1 == "I" { irx[$2] = $3; itx[$2] = $4 }
    END {
      # Registered sessions. A session file means ONLINE, whatever else says.
      # The counters are 0 when the device or rule is already gone.
      for (i = 1; i <= nf; i++) {
        name = fname[i]
        u = fuser[i]
        if (name ~ /^ppp[0-9]+$/) {
          claimed_dev[name] = 1
          if (name in hasdev) addsess(u, "L2TP(" name ")", drx[name], dtx[name])
          else addsess(u, "L2TP(" name ")", 0, 0)
        } else if (name ~ /^ikev2_/) {
          vip = fpeer[i]
          if (vip !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) vip = substr(name, 7)
          claimed_vip[vip] = 1
          addsess(u, "IKEv2(" vip ")", max(srx[vip], irx[vip]), max(stx[vip], itx[vip]))
        } else {
          addsess(u, name, 0, 0)
        }
      }
      # Sessions the kernel or strongSwan show but no hook registered.
      for (dev in hasdev) {
        if (dev in claimed_dev) continue
        addsess("L2TP_" (dpeer[dev] == "-" ? dev : dpeer[dev]), "L2TP(" dev ")", drx[dev], dtx[dev])
      }
      for (i = 1; i <= ns; i++) {
        vip = svip[i]
        if (vip in claimed_vip) continue
        claimed_vip[vip] = 1
        addsess((suser[i] == "-" ? "IKEv2_" vip : suser[i]), "IKEv2(" vip ")", max(srx[vip], irx[vip]), max(stx[vip], itx[vip]))
      }
      for (u in users) printf "%s %.0f %.0f %s\n", u, r[u], t[u], (st[u] == "" ? "-" : st[u])
    }
  ' "$facts" | LC_ALL=C sort || rc=$?
  rm -f "$facts"
  return "$rc"
}

show_stats() {
  echo "--------------------------------------------------------------------------------"
  printf "%-16s | %-12s | %-12s | %-12s | %-18s\n" "USERNAME" "UPLOAD" "DOWNLOAD" "TOTAL USED" "STATUS"
  echo "--------------------------------------------------------------------------------"
  usage_rows | awk '
    function human(x) {
      split("B KB MB GB TB", v, " ")
      s = 1
      while (x >= 1024 && s < 5) { x /= 1024; s++ }
      return sprintf("%.2f %s", x, v[s])
    }
    {
      st = $4
      if (st == "-") st = "offline"
      else { gsub(/,/, ", ", st); st = "ONLINE: " st }
      printf "%-16s | %-12s | %-12s | %-12s | %-18s\n", $1, human($2), human($3), human($2 + $3), st
    }
  '
  echo "--------------------------------------------------------------------------------"
}

if [ "$ACT" = "add" ]; then
  if [ -z "$USR" ]; then
    echo "Usage: l2tp-user <username> [password]"
    exit 1
  fi
  if [ -z "$PAS" ]; then
    PAS=$(openssl rand -hex 6)
  fi
  sed -i "/^\"*$USR\"*[[:space:]]/d" /etc/ppp/chap-secrets /etc/ppp/pap-secrets
  echo "\"$USR\" l2tpd \"$PAS\" *" >> /etc/ppp/chap-secrets
  echo "\"$USR\" l2tpd \"$PAS\" *" >> /etc/ppp/pap-secrets
  rebuild_ipsec_secrets
  ipsec rereadsecrets >/dev/null 2>&1 || true
  echo "=========================================="
  echo "Server IP:                $SERVER_IP"
  echo "Username / IPsec ID:      $USR"
  echo "Password / User PSK:      $PAS"
  echo "Master IPsec PSK:         $MASTER_PSK"
  echo "Modem Hostname:           modem"
  echo "Modem Tunnel Password:    $TUN_PASS"
  echo "=========================================="
elif [ "$ACT" = "del" ]; then
  sed -i "/^\"*$USR\"*[[:space:]]/d" /etc/ppp/chap-secrets /etc/ppp/pap-secrets
  rebuild_ipsec_secrets
  ipsec rereadsecrets >/dev/null 2>&1 || true
  echo "Removed user: $USR"
elif [ "$ACT" = "reset" ]; then
  if [ -n "$USR" ]; then
    sed -i "/^$USR /d" "$DB"
    echo "Reset bandwidth usage for user: $USR"
  else
    : > "$DB"
    echo "Reset bandwidth usage for ALL users."
  fi
elif [ "$ACT" = "logs" ]; then
  if [ ! -s /var/log/vpn-usage/sessions.log ]; then
    echo "No session events recorded yet."
  else
    tail -n 50 /var/log/vpn-usage/sessions.log
  fi
elif [ "$ACT" = "stats" ]; then
  show_stats
elif [ "$ACT" = "usage" ]; then
  usage_rows
else
  echo "================================================================================"
  echo "Server IP: $SERVER_IP   (secrets are shown only on a user card: ezl2tp card <user>)"
  show_stats
  echo "Commands: l2tp-user add <user> <pass> | l2tp-user stats | l2tp-user reset [user] | l2tp-user logs"
fi
USER_SCRIPT
chmod +x /usr/local/bin/l2tp-user

# --- Panel: copy from next to this script if present, else try the repo ---
# The panel command was renamed from vpn-panel to ezl2tp.
# Remove the old name so a server does not end up with two commands.
rm -f /usr/local/bin/vpn-panel 2>/dev/null || true
PANEL_INSTALLED=0
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
if [ -f "$SELF_DIR/ezl2tp" ]; then
  cp "$SELF_DIR/ezl2tp" /usr/local/bin/ezl2tp 2>/dev/null || true
  chmod +x /usr/local/bin/ezl2tp 2>/dev/null || true
  PANEL_INSTALLED=1
else
  BRANCH="${EASYL2TP_BRANCH:-main}"
  if curl -fsSL --max-time 15 "https://raw.githubusercontent.com/hesamhanari/easyl2tp/${BRANCH}/ezl2tp" -o /usr/local/bin/ezl2tp 2>/dev/null; then
    chmod +x /usr/local/bin/ezl2tp 2>/dev/null || true
    PANEL_INSTALLED=1
  fi
fi
if [ "$PANEL_INSTALLED" != "1" ]; then
  echo "NOTE: ezl2tp could not be installed automatically (repo is private or panel file was not next to install.sh)."
  echo "Install it later with: cp ezl2tp /usr/local/bin/ezl2tp && chmod +x /usr/local/bin/ezl2tp"
fi

systemctl daemon-reload
systemctl disable --now strongswan strongswan-swanctl 2>/dev/null || true
systemctl enable --now strongswan-starter xl2tpd l2tp-firewall
systemctl restart strongswan-starter xl2tpd l2tp-firewall

# Fail loudly if a service did not come up, instead of printing "Ready".
FAILED=""
for s in strongswan-starter xl2tpd l2tp-firewall; do
  systemctl is-active --quiet "$s" || FAILED="$FAILED $s"
done
if [ -n "$FAILED" ]; then
  echo "ERROR: these services are not running:$FAILED" >&2
  echo "Look at: journalctl -u <service> --no-pager | tail -n 30" >&2
  exit 1
fi

echo "=================================================="
echo "easyl2tp VPN Server Ready on $SERVER_IP"
echo "=================================================="
echo "Kernel:    $(uname -r)"
echo "Services:  strongswan-starter, xl2tpd, l2tp-firewall (all active)"
echo "Backups:   $BACKUP_DIR"
echo "--------------------------------------------------"
echo "Secrets were generated or reused and are stored only on this"
echo "server, root-only, in /etc/ipsec.secrets (master IPsec PSK),"
echo "/etc/xl2tpd/l2tp-secrets (modem tunnel password) and"
echo "/etc/ppp/chap-secrets (users). They are NOT printed here."
echo "--------------------------------------------------"
echo "Next steps:"
echo "  1. Add a user:        ezl2tp add <username>"
echo "  2. Show their card:   ezl2tp card <username>"
echo "     (a card holds that user's secrets - share it only with them)"
echo "  3. Open the panel:    ezl2tp"
echo "=================================================="
