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
- A bash panel, `ezl2tp`, with an interactive menu (see "The panel" below)
  and one-shot commands:
  - `status` (kernel, PPP device, services, ports, users online)
  - `users` (online/offline, upload/download/total — including the
    traffic of sessions that are still connected, not only finished ones)
  - `live` sessions, `logs`, `stats`
  - `add` / `del` a user, `card` for one user's connection card
  - per-user data limits (`ezl2tp limit <user> <GB>`), see "Data limits"
  - `restart` the VPN services
  - `backup` / `backups` / `update`, see "Backup, updates and uninstall"
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
1. Checks root, Debian 13 (other versions are refused) and a public IPv4.
2. Checks PPP kernel support FIRST (modules load and `/dev/ppp` opens),
   before installing or stopping anything. Most servers pass and the
   install just continues. If PPP is disabled in the kernel (Debian
   cloud kernels, `...-cloud-amd64`), see "Cloud kernel without PPP"
   below — the installer can fix it, but only if you say so.
3. Generates the master IPsec PSK and modem tunnel password
   with `openssl rand` — unless you pass `TUNPW` / `IPSEC_PSK`
   in the environment to rotate them on purpose, or unless a
   previous install already has them, in which case it reuses
   them so existing users keep working.
4. Backs up any existing configs to `/root/easyl2tp-backup-*` (the panel's
   Backup menu makes and restores the same kind of folder).
5. Installs strongswan-starter (L2TP/IPsec IKEv1 + IKEv2),
   xl2tpd, firewall/NAT, usage tracking, `l2tp-user`, and
   `ezl2tp` if it can find it, and records the installed commit in
   `/var/lib/easyl2tp/version`.
6. Prints only the next steps at the end. The secrets are NOT printed:
   they live in root-only files on the server, and each user's card
   (`ezl2tp card <user>`) shows what that user needs.

Re-running the installer is safe for users: it reuses existing
secrets and preserves existing users in chap-secrets and their data limits.
(The panel's *Check For Updates* is this re-run, with a backup first.)

### Cloud kernel without PPP (extra steps)

Some VPS images boot a Debian *cloud* kernel that has PPP compiled out.
L2TP cannot work on it, and no package or `modprobe` can change that.
On such a server the installer stops at step 2 and offers to swap in the
stock Debian kernel:

1. It prints a warning in red capitals: **this cannot be undone**, the
   cloud kernel will be removed, and if the stock kernel fails to boot
   you will lose SSH. Before you go on, check that your provider gives
   you console access (VNC / serial / rescue) and, on a real server,
   take a snapshot.
2. It does nothing until you type exactly `YES` (capitals; `y` and `yes`
   cancel, and nothing is changed).
3. After `YES` it installs `linux-image-amd64`, checks that the new
   kernel is really there and has PPP, removes the cloud kernel, runs
   `update-grub`, then reboots with a 5-4-3-2-1 countdown. If any of
   those steps fails, it stops *before* the reboot and says what to fix.
4. Your SSH session ends with the reboot. The last line before the
   countdown is `IMPORTANT: AFTER THE REBOOT, START THE SCRIPT AGAIN:
   bash ./install.sh`, so it is the thing still on your screen when the
   connection drops. Wait about a minute, log in again, and **run the
   installer again**. PPP now passes and the real install starts.

If the server comes back on a cloud kernel anyway (the provider boots
its own kernel and ignores `/boot`), the installer stops with
`this VPS cannot run L2TP` and does not try again — use a different VPS
image or plan. The installer asks for the terminal, so run it from an
interactive SSH session, not piped into `bash`.

## The panel

Run `ezl2tp` as root. The main menu is exactly this:

```
1 Status
2 User Management
3 Live sessions
4 Logs
5 Restart services
6 Backup
7 Check For Updates
8 Uninstall
0 Exit
```

Everything that is about one user lives under **2 User Management**:

```
1 Show all users
2 Add user
0 Back
```

**Show all users** is one numbered table with every user's status, upload,
download, total and data limit. Rows of users who are connected are
**green**, rows of users who are offline are **red** (a user who is over
their limit shows `BLOCKED` in the status column). The numbers are the same
ones `ezl2tp users` and `l2tp-user stats` print: the saved totals plus the
live counters of open sessions. Type a user's number to open that user:

```
1 Show card
2 Change password
3 Set / clear data limit
4 Reset data
5 Disconnect now
6 Delete user
0 Back
```

- **Change password** keeps the user's limit and usage. A session that is
  connected right now keeps working until it reconnects.
- **Set / clear data limit**: a number of GB (`50`, `12.5`), or `0` / `clear`
  for unlimited; Enter cancels.
- **Reset data** and **Delete user** ask you to type `YES`.
- **Disconnect now** ends the user's live L2TP and IKEv2 sessions. It blocks
  nothing: the user can reconnect at once (a data limit is what keeps a user
  out).

**Add user** asks for the name, then the password (Enter = a random one),
then the data limit in GB: **Enter = 1 GB**, `0` or `clear` = unlimited. It
shows the new user's card at the end. Users that already exist keep their
current limit or unlimited state; the 1 GB default only applies to users
added from this menu (`ezl2tp add <user>` on the command line adds an
unlimited user, as before).

The old separate top-level items (Users, Bandwidth stats, Add, Delete, Card)
moved under User Management. The one-shot commands did not change:
`ezl2tp status`, `users`, `stats`, `live`, `logs`, `add`, `del`, `card`,
`limit` and `restart` all still work. Colors only show on a terminal.

### Backup, updates and uninstall

**6 Backup** has *Create backup*, *List backups* and *Restore backup*.
A backup is a folder `/root/easyl2tp-backup-YYYYmmdd-HHMMSS` (mode `0700`) with
the same files `install.sh` backs up before it overwrites them (ipsec,
strongSwan, xl2tpd, ppp options, chap/pap secrets, sysctl) plus the panel
and `l2tp-user`, the firewall script, the totals database, the limits
database and the sessions log, under their original paths. The panel prints
**only the path**, never a secret; the backup itself holds your secrets, so
keep it private. `ezl2tp backup` does the same from the command line and
prints just the path; `ezl2tp backups` lists them.

*Restore* asks for the backup's number and then for `YES`. It first makes a
fresh backup of the current state (and tells you where), then puts the files
back and restarts strongswan-starter, xl2tpd and l2tp-firewall. Backups
written by `install.sh` itself are flat copies; they are listed but you copy
those back by hand. After an Uninstall, run `install.sh` first, then restore.

**7 Check For Updates** compares the commit this server was installed from
(`/var/lib/easyl2tp/version`, written by `install.sh`) with the tip of `main`
on GitHub. If they differ it says so and asks you to type `YES`; then it
takes a backup and runs the installer from `main` again. That is the normal
re-run: your users, secrets (master PSK, tunnel password) and data limits are
kept. A server installed before version tracking has no recorded version: the
panel says so, offers the update anyway (the next install records it) and
does not fail. If GitHub cannot be reached (offline, rate limit, private
repo) it says that and changes nothing. `ezl2tp update` does the same from the
command line.

**8 Uninstall** asks you to type `YES`, **takes a backup first** (if that
fails nothing is removed), then stops and disables `strongswan-starter`,
`xl2tpd`, `l2tp-firewall` and `easyl2tp-limits.timer`, and removes the
`ezl2tp` panel and the `l2tp-user` CLI. The backup is kept, always: nothing
in the panel ever deletes one. Users, secrets, limits and logs stay on disk
(and in the backup); install again with `install.sh` and restore if you want
them back.

### Traffic numbers are live

`ezl2tp users`, `ezl2tp status` and `l2tp-user stats` all show the
saved totals **plus** what connected users are using right now (ppp
interface counters for L2TP, firewall counters per user address for
IKEv2). Online status comes from the live session files, so a connected
user is never shown as offline. When a user disconnects, their final
bytes move into the saved totals — nothing is counted twice.

## Data limits

Cap how much a user can transfer per 30 days. Upload and download count
together.

```bash
ezl2tp limit test-user1 50       # 50 GB per 30 days
ezl2tp limit test-user1 12.5     # decimals are fine
ezl2tp limit test-user1 clear    # unlimited again
```

(`l2tp-user limit <user> <GB|clear>` does the same; the panel just calls
it, so the two always agree. GB here means 1024 x 1024 x 1024 bytes, the
same GB the panel prints.) In the menu it is under User Management > Show
all users > (pick a user) > Set / clear data limit.

**What counts.** The same numbers as `ezl2tp users`: the saved totals plus
what connected sessions are using right now. A disconnect moves the live
bytes into the saved totals, so nothing is counted twice. A user is over
the limit when used is **at or above** the limit.

**The period** is per user and rolling, 30 days, and it starts at that
user's **first connection after the limit was set** (not on the 1st of a
month). Two users with the same limit have different period ends. When the
period has run out, that user's **next connection resets their totals to
zero and starts a new period** by itself, with no admin action. Totals are
a per-period quota while a limit is set, so they also start from zero at
that first connection (older history is not counted against the new quota;
write it down first if you need it).

**Enforcement is a block**, for both L2TP/ppp and IKEv2:

- A user who is at or over the limit is **refused**: the new session is
  ended within about a second, before it is registered or counted.
- A user who goes over while connected is **disconnected**. A systemd timer
  (`easyl2tp-limits.timer`) checks every 30 seconds, so a user can overshoot
  by up to 30 seconds of traffic. This is a cap, not billing-grade metering.
- The user stays blocked until their period ends; then the next connection
  starts a fresh period. A limit is also lifted at once by raising it or
  with `ezl2tp limit <user> clear`.
- A user with no limit is **never** blocked.

**Manual reset.** `l2tp-user reset <user>` sets that user's usage to zero and
restarts their period from now. The limit itself is kept (`l2tp-user reset`
with no user does this for everybody). Use it to unblock a user early, and
to start the period at once for an always-on modem that was already
connected when you set the limit (otherwise its period starts at its next
connection).

**What you see.** `ezl2tp users` shows a LIMIT column (`unlimited` when none)
and, under each limited user, used, left and the period end date. A user over
the limit shows `BLOCKED` in the STATUS column. `ezl2tp card <user>` has the
same information: limit, used, remaining, period end, and OK or BLOCKED.
Dates are UTC.

**Where it is stored.** `/var/lib/easyl2tp/limits.db` (root only), a
separate file from `totals.db`, so resetting usage never erases a limit and a
re-install keeps them. Deleting a user removes their limit. An older server
needs the installer run once more to get this (your users are kept); until
then `ezl2tp limit` says so instead of doing anything.

## Current files

- `install.sh` — the one-line installer above.
- `ezl2tp` — the panel script. Works on top of an already
  installed L2TP/IKEv2 server that uses:
  - `/etc/ppp/chap-secrets` for users
  - `/var/log/vpn-usage/totals.db` and `sessions.log` for usage
  - `/run/vpn-sessions/*` for live sessions
  - `/usr/local/bin/l2tp-user` for add/delete/stats/limits (the panel
    delegates to it, so secret handling stays in one place)
  - `/var/lib/easyl2tp/limits.db` for per-user data limits
  - `/var/lib/easyl2tp/version` for the installed commit (Check For Updates)
- `SPEC.md` — the build plan for Claude, in PR order.
- `AGENTS.md` — the multi-agent workflow for this project.
- `SECURITY.md` — what must never go into this repo.
- `tests/smoke-test.sh` — fake-data smoke test for the panel; also runs
  the four suites below.
- `tests/panel-test.sh` — the panel menus with fake users: the exact main
  menu, the numbered green/red table, every per-user action, Add user
  (1 GB default), backup create / list / restore, the update check and the
  uninstall guard. Runs the real `l2tp-user` from `install.sh` against a
  fake server tree.
- `tests/kernel-fix-test.sh` — the cloud-kernel auto-fix, run against
  stubbed apt/grub/reboot (the exact-`YES` rule, the order of steps,
  the no-loop rule after the reboot).
- `tests/live-stats-test.sh` — live traffic and online status for
  `l2tp-user` and the panel, including the IKEv2 regression.
- `tests/limits-test.sh` — data limits with fake data: set/clear, the
  30-day period and automatic reset, blocking on both protocols (the real
  ip-up and IKEv2 hooks), disconnecting live sessions, unlimited users, and
  what the panel shows.
- `tests/lint.sh` — shellcheck (including the scripts embedded in
  `install.sh`) and guards for settings that must not come back.
- `tests/fresh-vps-test.md` — how to test the installer on a fresh
  Debian 13 VPS (done by hand, on a throwaway server).

## Using the panel on an existing server (advanced users only)

```bash
cp ezl2tp /usr/local/bin/ezl2tp
chmod +x /usr/local/bin/ezl2tp
ezl2tp            # interactive menu, run as root
ezl2tp status
ezl2tp users
ezl2tp card <username>
```

Passwords are never shown in the users list — only on one user's
card, which must be shared only with that user.

## For Claude: start here

Read `AGENTS.md`, then `SPEC.md`. Work one PR at a time, one
session per PR. Do not start PR 2 until PR 1 is merged. Green
tests before ship.
