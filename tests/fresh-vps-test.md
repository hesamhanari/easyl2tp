# Fresh Debian 13 VPS test for install.sh

Run this on a **throwaway** Debian 13 VPS (not a server with real users).
Everything below uses fake names; no real credentials belong in this file.
The installer has only been checked statically so far (shellcheck, config
review, panel smoke test) — this checklist is the first real test.

## 0. Before you start
```bash
cat /etc/os-release | grep -E '^(PRETTY_NAME|VERSION_ID)='
uname -r
modprobe ppp_generic && ls -l /dev/ppp
```
`VERSION_ID="13"`; the `modprobe` must succeed. If the kernel ends in
`-cloud-amd64` and has no PPP, the installer must offer the kernel fix
and wait for an exact `YES` (see test 2b). Use a throwaway server for
that test: the cloud kernel is removed and the server reboots.

## 1. Fresh install
```bash
git clone https://github.com/hesamhanari/easyl2tp.git && cd easyl2tp
bash tests/lint.sh && bash tests/smoke-test.sh
sudo -i bash ./install.sh
```
Expected: ends with "Ready", three services active, **no PSK or tunnel
password printed**. Then:
```bash
ls -l /etc/ipsec.secrets /etc/xl2tpd/l2tp-secrets /etc/ppp/chap-secrets   # all -rw------- root
ezl2tp add test-user1
ezl2tp status ; ezl2tp users ; ezl2tp card test-user1
command -v vpn-panel || echo "old name gone"
```

## 2. Refusal tests (nothing may change)
- Non-Debian / Debian 12: installer exits with "tested on Debian 13 only".
- Kernel without PPP that is *not* a `-cloud-amd64` kernel: installer
  exits with the PPP message **before** `systemctl stop` — check
  `systemctl is-active xl2tpd` is unchanged.
- Another process on UDP 1701 (`nc -u -l 1701`): installer refuses and
  services are untouched.

## 2b. Cloud kernel without PPP: the kernel fix
Only on a throwaway VPS whose `uname -r` ends in `-cloud-amd64` and where
`modprobe ppp_generic` fails. **First** check the provider console works
and take a snapshot.
```bash
sudo -i bash ./install.sh      # run it from an interactive SSH session
```
1. The red warning appears first, before anything is installed. It says
   this **cannot be undone**, the cloud kernel will be removed, SSH is
   lost if the stock kernel does not boot, check console access and take
   a snapshot. Nothing has changed yet.
2. Cancel test: answer `y`, then `yes`, then just Enter, each time on a
   fresh run. Every one must print `Cancelled. Nothing was changed.`
   Check `uname -r` and `dpkg -l 'linux-image-*cloud*'` are unchanged
   and `/var/lib/easyl2tp/kernel-fix` does not exist.
3. Real run: answer exactly `YES`. It installs `linux-image-amd64`,
   removes the cloud kernel, runs `update-grub`, prints the instruction
   to re-run the installer, counts `5 4 3 2 1`, and reboots.
4. Log in again (use the console if SSH does not come back and report
   what you see). `uname -r` must **not** end in `-cloud-amd64`, and
   `modprobe ppp_generic && ls -l /dev/ppp` must work.
5. Run `sudo -i bash ./install.sh` again. It must print
   `PPP kernel support: OK`, continue straight into the normal install
   (no second warning, no second reboot) and end with "Ready".
   `/var/lib/easyl2tp/kernel-fix` must be gone afterwards.
6. If the server comes back on a cloud kernel anyway, the re-run must
   stop with `this VPS cannot run L2TP` and must **not** offer the fix
   or reboot again. Report the provider and image name.

## 3. Re-run is safe
```bash
cp /etc/ipsec.secrets /root/ipsec.before
sudo bash ./install.sh
diff <(grep '^: PSK' /root/ipsec.before) <(grep '^: PSK' /etc/ipsec.secrets) && echo "PSK reused"
ezl2tp users            # test-user1 still there
ls /root/easyl2tp-backup-*
```

## 4. Real clients (the part only a person can test)
Use `ezl2tp card test-user1` and connect:
1. **iPhone** built-in L2TP/IPsec (main mode, shared PSK).
2. **Android TunnelForge** L2TP/IPsec.
3. **Android built-in IKEv2/IPsec PSK** (ID = username, PSK = user password).
4. **Modem, plain L2TP (no IPsec)** with the tunnel password from the card.
   This must still work: `require authentication = yes` only adds PPP auth,
   which `options.xl2tpd` already demanded.

For each: internet works (`curl ifconfig.me` shows the server IP) and
`ezl2tp users` shows it ONLINE, then offline with traffic counted afterwards.

**Live traffic** (check this for the IKEv2 phone and the L2TP phone/modem):
while the client is connected and downloading something,
```bash
l2tp-user stats ; ezl2tp users ; ezl2tp status
```
- `l2tp-user stats` and `ezl2tp users` both show `ONLINE: IKEv2(10.99.1.x)`
  or `ONLINE: L2TP(pppN)` for that user, and never `offline`.
- Upload/download grow between two runs a few seconds apart, and the
  `ezl2tp users` numbers match `l2tp-user stats`. `ezl2tp status` total
  traffic includes them too.
- Note the user's TOTAL, disconnect the client, wait a few seconds, and
  run `l2tp-user stats` again: the user is `offline` and the TOTAL is
  about the same as just before (a little more is fine; roughly double is
  a bug — report it).
If a client that worked before now fails right at the IKE step, check
`journalctl -u strongswan-starter | grep -i aggressive` — that client uses
IKEv1 aggressive mode (see PR description for what to do).

## 5. Revocation and IKEv2 check
```bash
ezl2tp del test-user1       # type YES
grep -c test-user1 /etc/ipsec.secrets    # expect 0
```
Then try IKEv2 with ID `test-user1` and the **shared master PSK**. Report
whether it connects: if it does, the master PSK also works for IKEv2 and
per-user revocation does not cover IKEv2 (open question in the PR).
