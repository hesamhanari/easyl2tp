# VPN panel — repo plan for Claude (draft, not yet a repo)

Goal: turn the working mehr23 L2TP + IKEv2 setup and the vpn-panel
script into a clean, newbie-friendly project that can someday be
published. Start PRIVATE. Publish only after the release checklist
below is green.

## What exists today (starting point, not the finished product)
- A working installer script (Gemini Argon, 2026-11-01) that sets up
  strongswan-starter + /etc/ipsec.conf (L2TP/IPsec IKEv1 + IKEv2),
  xl2tpd, firewall/NAT, and usage tracking
  (/var/log/vpn-usage, /usr/local/bin/l2tp-user).
- vpn-panel (Rio, 2026-11-01): bash TUI/CLI on top of l2tp-user,
  chap-secrets, totals.db and /run/vpn-sessions. Syntax-checked and
  smoke-tested against fake data. It delegates add/del to l2tp-user
  and does not rewrite the installer configs.

## Proposed repo: easyl2tp (created 2026-11-01, private)
- README.md — newbie guide: what it is, who it is for, prerequisites
  (a Debian 13 VPS, root SSH, a public IPv4), one-command install,
  first user, modem / Android / iPhone setup, screenshots of the menu.
- install.sh — cleaned installer (see PR 1).
- vpn-panel — the panel script, installable to /usr/local/bin.
- l2tp-user — the existing user/stats CLI, kept compatible.
- docs/
  - modem-l2tp.md (plain L2TP only, tunnel password, no PSK field)
  - android.md (TunnelForge for L2TP, built-in IKEv2/IPsec PSK)
  - iphone.md (built-in L2TP/IPsec)
  - troubleshooting.md (PPP kernel problem, firewall, logs)
- tests/ — shellcheck + a fake-data smoke test for the panel
  (same style as Rio's /tmp test: fake chap-secrets, totals.db,
  live session files; check users/live/card/status output).
- LICENSE (MIT, to confirm) and SECURITY.md.

## PR 1 — installer (status: built by Rio 2026-11-01, needs review + fresh-VPS test)
`install.sh` in this repo is already built from the tested Gemini
script, with random secret generation, a PPP check before any
destructive step, backups, and reuse of existing secrets on
re-install. Claude's PR 1 job is now REVIEW + TEST, not a rewrite
from scratch, unless the review finds a reason to rewrite:
review the installer against the acceptance criteria below,
fix what fails, and test it on a fresh Debian 13 VPS.

Original PR 1 acceptance criteria (still apply):
Acceptance criteria:
- No hardcoded passwords, PSKs, tunnel passwords, server IPs, or
  usernames anywhere in the repo, docs, or tests. Secrets are
  generated at install time (openssl rand) or prompted for, and
  stored only on the server (root-only files).
- Review and, where safe, remove the insecure settings carried over
  from the working script — in particular any
  "i_dont_care_about_security" style flag and any overly broad
  firewall/NAT rule — and explain each change in the PR description.
  Do not break the modem plain-L2TP path while doing this.
- Installer is idempotent where possible: re-running it must not
  wipe existing users, and it must back up any config it overwrites
  to a timestamped directory before writing.
- Installer checks, before doing anything destructive:
  - running as root, Debian 13, public IPv4 available
  - PPP actually works on the running kernel: /dev/ppp can be
    opened, or ppp_generic/pppol2tp/l2tp_ppp load. If not, it must
    STOP with a clear message (see troubleshooting.md) instead of
    installing a server that can never connect. This is the lesson
    from mehr23: Debian cloud kernels can ship with PPP disabled
    entirely (CONFIG_PPP not set), and no mknod/modprobe fixes that;
    the fix is a PPP-enabled kernel (e.g. stock linux-image-amd64)
    and a verified reboot into it.
- Installer prints, at the end, only the admin next steps and where
  the per-user cards live — it must not print every secret to the
  log by default.
- shellcheck clean, and a fresh-VPS install test is described in
  the PR (even if Hesam runs it by hand).

## PR 2 — Claude: panel polish
- Keep the current panel behaviour and data formats (chap-secrets,
  totals.db, /run/vpn-sessions) so existing servers keep working.
- Optional whiptail/dialog menu if installed, plain bash menu as
  fallback. No new hard dependencies.
- Add: search/filter users, sort by usage, show last session from
  sessions.log, export a single user's card to a file (for sharing)
  without printing other users' secrets.
- Keep the fake-data smoke test green.

## PR 3 — Claude: docs + release checklist
- Docs written for a newbie who has never run a VPS: what a VPS is,
  how to SSH in, what each menu item does, what to do when the
  modem says Disconnected, how to read the logs.
- Release checklist (all must be true before going public):
  - grep for secrets, IPs, usernames, and the old mehr23-specific
    values returns nothing in the repo
  - fresh Debian 13 install + TunnelForge + modem-style plain L2TP
    test both pass, or the failure is documented
  - README install command works from a clean checkout
  - SECURITY.md explains: PSK sharing, per-user revocation,
    why PPTP is not offered, and that L2TP/IPsec PSK is shared
    by design for L2TP (per-user PSK only for IKEv2)

## Workflow (per Hesam's adopted multi-agent workflow)
- One writer at a time. Claude builds, one PR at a time.
- One session per PR: fixes to an open PR stay in that PR's
  session; a merged branch means a new session for the next change.
- Green tests before ship. Gemini/Antigravity reviews before
  any public release; Rio re-checks the diff and gives the
  copy-paste deploy/install commands. Deploys/installs on a real
  server are Hesam's hands.
- New projects start in a PRIVATE GitHub repo. Public is a
  separate, explicit decision later.

## Out of scope for now
- A web panel (the TUI/CLI is the product; web UI is a later
  decision, with its own auth/security review).
- WireGuard/VLESS management (3x-ui already covers that on
  mehr23; do not duplicate it here).
- Automatic migration of an existing mehr23 server (document
  a manual path instead, if needed).
