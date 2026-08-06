# Contributing

Thanks for helping. The most valuable contribution here is telling us when an
example has stopped working — a broken example is worse than a missing one.

## Reporting a problem

[Open an issue](https://github.com/musher-dev/examples/issues/new/choose) with
the example name, what you ran, and what happened. If a deploy failed, the
deployment id helps.

Security issues go to [SECURITY.md](./SECURITY.md), not the issue tracker.

## The bar for an example

Every example here is a teaching artifact first and an app second. Before
opening a pull request, check it against this list.

**It teaches exactly one new thing.** Examples form a ladder: each adds a single
idea to the one before it. An example that introduces volumes *and* connections
*and* a worker teaches none of them well. Split it.

**It is the smallest app that demonstrates the idea.** No framework unless the
idea requires one, no dependency that a reader has to evaluate before they can
read the code. Standard library is the default.

**The Musher specs are the point.** `musher/component.yaml` and
`musher/blueprint.yaml` carry comments explaining *why*, not *what* — a reader
can see what a field is set to. Explain the constraint they cannot see: that
`protocol` has no wire default, that a public `SERVICE` must declare readiness.

**It runs as a non-root user and pins its base image by digest.** Resolve the
digest rather than copying one:

```bash
docker buildx imagetools inspect python:3.13-slim | grep '^Digest:'
```

**The image tag is a real version.** Floating tags (`:latest`, `:main`,
`:edge`) build fine and are rejected when the Component is published.

**It declares a readiness probe if it serves public traffic**, and the probe is
honest — it answers "can I serve a request right now", not "is the process
alive".

**Its README follows the house shape:** what it teaches, before you start,
numbered steps, verify, what the specs say, hack on it, next. Include the
`curl`-by-`curl` path in a `<details>` block so nothing the script does is
hidden.

## Layout

```
<example>/
├── README.md
├── Dockerfile
├── .dockerignore
├── src/
└── musher/
    ├── component.yaml      one per workload; component-<name>.yaml if several
    └── blueprint.yaml
```

`scripts/musher-apply.sh` discovers `musher/component*.yaml` by glob and exports
each published component as `${SLUG_COMPONENT_ID}` / `${SLUG_COMPONENT_VERSION}`
for `blueprint.yaml` to reference, with `-` becoming `_` and the slug uppercased.

## Checks

CI builds every Dockerfile and parses every spec. Run the same thing locally:

```bash
shellcheck scripts/*.sh
for d in */; do [ -f "$d/Dockerfile" ] && docker build -q -t "check/${d%/}" "$d"; done
for f in */musher/*.yaml; do yq -e 'has("specVersion") and has("kind") and has("spec")' "$f" >/dev/null \
  || echo "malformed: $f"; done
```

Verify an example end to end before submitting it: build, push, apply, and open
the URL. "It should work" is not a check.

## Style

Prose is second person and active. Use the platform's own vocabulary —
Component, Blueprint, Deployment, Instance, Volume, Organization — as defined in
the [glossary](https://docs.musher.dev/glossary). Say "organization", never
"workspace".

## License

Contributions are accepted under [Apache-2.0](./LICENSE).
