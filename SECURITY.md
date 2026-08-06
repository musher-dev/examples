# Security policy

## Reporting a vulnerability

Report security issues privately through
[GitHub Security Advisories](https://github.com/musher-dev/examples/security/advisories/new).
Please do not open a public issue.

We aim to acknowledge within two business days.

If the issue is in the Musher platform itself rather than in these examples,
report it at
[musher-dev/platform](https://github.com/musher-dev/platform/security/advisories/new).

## What these examples are, and are not

The applications here are **teaching artifacts**. They are built to be read and
taken apart, not to be deployed as-is and left running.

They do get the basics right — pinned base images, non-root users, no secrets in
the repository, no floating tags — because those are part of what they teach.

They deliberately have **no authentication, no authorization, no rate limiting,
no input hardening, and no backups**. Adding those would bury the one idea each
example exists to demonstrate. Treat every example as a starting point you are
expected to secure before it holds anything real.

## Secrets

Nothing in this repository is a real credential. `MUSHER_API_KEY` and any
registry token stay in your environment.

Where an example needs a secret, it declares it as a Component input with a
`generator`, so the platform mints it at deploy time and it never exists in a
file. That is the pattern to copy.

If you believe a real secret has been committed here, report it through the
advisory link above rather than opening an issue.
