# Security

Report vulnerabilities privately with
[private vulnerability reporting](https://github.com/AlikhanSharapov01/SiteLock/security/advisories/new).
Please do not open a public issue.

## In scope

- The root daemon (`sitelockd`)
- Password handling (hashing, storage, throttling)
- The control socket (`/var/run/sitelockd.sock`)

## Out of scope

SiteLock is a barrier against impulse, not a lock against yourself. Anyone with admin rights can
remove it by design; that is not a vulnerability.
