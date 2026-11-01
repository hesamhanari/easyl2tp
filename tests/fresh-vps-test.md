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
`-cloud-amd64` and has no PPP, the installer must refuse (see test 2).

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
- Kernel without PPP: installer exits with the PPP message **before**
  `systemctl stop` — check `systemctl is-active xl2tpd` is unchanged.
- Another process on UDP 1701 (`nc -u -l 1701`): installer refuses and
  services are untouched.

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
