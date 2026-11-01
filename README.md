# easyl2tp

A simple L2TP + IKEv2 VPN server with a terminal panel for managing
users, live sessions, and bandwidth usage — built for people who are
new to running their own VPS.

**Status: private work in progress. Do not publish yet.**
`install.sh` now exists in this repo, built from the tested
Gemini script with random secret generation (see below). It has
not yet been tested on a fresh VPS — test it on a spare server
before using it for a real user, and before any public release.

## What this will be

- An L2TP/IPsec server (IKEv1, for modems and phones that still use
  L2TP) plus an IKEv2 server (for modern phones with built-in
  IKEv2/IPsec PSK support), on a Debian 13 VPS.
- A bash panel, `vpn-panel`, with an interactive menu and one-shot
  commands:
  - status (kernel, PPP device, services, ports, users online)
  - users (online/offline, upload/download/total)
  - live sessions, session logs, bandwidth stats
  - add/delete a user, show one user's connection card
  - restart the VPN services
- Usage tracking per user, so an admin can see who used how much.

## What it is not (yet)

- Not a web panel. The terminal panel is the product for now.
- Not a WireGuard/VLESS manager. Tools like 3x-ui already cover
  those; this project is for the cases where only L2TP/IKEv2 will
  do — for example a home modem that offers only PPTP and L2TP.
- Not a PPTP server. PPTP is deliberately not offered: its
  encryption is broken.

## Install (Debian 13, root, fresh VPS recommended)

One-line installer, like 3x-ui / backpack installers:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/hesamhanari/easyl2tp/main/install.sh)
```

While this repo is private, that raw URL needs GitHub auth and
will not work anonymously. Until it goes public, clone the repo
(private, needs GitHub auth) and run `./install.sh` from the
checkout, or copy `install.sh` to the server and run it there.

What the installer does, in order:
1. Checks root and Debian 13.
2. Checks PPP kernel support FIRST, before stopping anything.
   If PPP is disabled in the kernel (some Debian cloud kernels),
   it stops with a clear message instead of installing a broken
   server. Fix that kernel first, then re-run.
3. Generates the master IPsec PSK and modem tunnel password
   with `openssl rand` — unless you pass `TUNPW` / `IPSEC_PSK`
   in the environment to rotate them on purpose, or unless a
   previous install already has them, in which case it reuses
   them so existing users keep working.
4. Backs up any existing configs to `/root/easyl2tp-backup-*`.
5. Installs strongswan-starter (L2TP/IPsec IKEv1 + IKEv2),
   xl2tpd, firewall/NAT, usage tracking, `l2tp-user`, and
   `vpn-panel` if it can find it.
6. Prints the server IP and the two secrets at the end, on the
   server terminal only. Save them — do not share them publicly.

Re-running the installer is safe for users: it reuses existing
secrets and preserves existing users in chap-secrets.

## Current files

- `install.sh` — the one-line installer above.
- `vpn-panel` — the panel script. Works on top of an already
  installed L2TP/IKEv2 server that uses:
  - `/etc/ppp/chap-secrets` for users
  - `/var/log/vpn-usage/totals.db` and `sessions.log` for usage
  - `/run/vpn-sessions/*` for live sessions
  - `/usr/local/bin/l2tp-user` for add/delete/stats (the panel
    delegates to it, so secret handling stays in one place)
- `SPEC.md` — the build plan for Claude, in PR order.
- `AGENTS.md` — the multi-agent workflow for this project.
- `SECURITY.md` — what must never go into this repo.
- `tests/smoke-test.sh` — fake-data smoke test for the panel.

## Using the panel on an existing server (advanced users only)

```bash
cp vpn-panel /usr/local/bin/vpn-panel
chmod +x /usr/local/bin/vpn-panel
vpn-panel            # interactive menu, run as root
vpn-panel status
vpn-panel users
vpn-panel card <username>
```

Passwords are never shown in the users list — only on one user's
card, which must be shared only with that user.

## For Claude: start here

Read `AGENTS.md`, then `SPEC.md`. Work one PR at a time, one
session per PR. Do not start PR 2 until PR 1 is merged. Green
tests before ship.
