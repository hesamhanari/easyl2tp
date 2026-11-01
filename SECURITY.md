# Security rules for this repo

These rules are hard. A PR that breaks one of them must not merge,
even if everything else in it works.

1. No secrets in this repo. Ever. No passwords, IPsec PSKs, tunnel
   passwords, server IPs, usernames from a real server, API keys,
   or `.env` files. Test data in `tests/` must use obviously fake
   values (for example `test-user`, `test-pass-...`) and must say
   so in a comment.
2. Secrets are generated at install time on the server only, and
   stored in root-only files on that server. They are never printed
   in full to logs, issues, or PR descriptions.
3. A user's card contains that user's secrets. Share a card only
   with that user, never in a group chat, screenshot, or issue.
4. Revocation is per user: deleting a user from chap-secrets (via
   `l2tp-user del`) must also remove that user's IPsec secret.
   An already-connected session stays up until it disconnects or
   the service restarts — that limitation must stay documented.
5. PPTP is not offered. Its encryption is broken.
6. L2TP/IPsec uses a shared PSK by design for L2TP clients. That
   limitation must stay documented in the README/docs, along with
   the fact that IKEv2 can use a per-user PSK.
7. If a secret ever leaks into this repo, rotate it on the server
   first, then remove it from the repo history, and say so plainly
   in the PR — do not just delete the file and hope nobody saw it.
