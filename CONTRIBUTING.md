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
`protocol` has no default, that an endpoint a Blueprint exposes `PUBLIC` must
have a readiness probe. Every claim in a comment must be true of the pinned
specification ([`pins/`](./pins)); when the specification changes, the comments
are part of the bump.

**It runs as a non-root user and pins its base image by digest.** Resolve the
digest rather than copying one:

```bash
docker buildx imagetools inspect python:3.13-slim | grep '^Digest:'
```

**The image tag is a real version.** Musher accepts a floating tag (`:latest`,
`:main`, `:edge`) and pins whatever digest it resolves at deploy time, so the
same Component revision can run different code from one deployment to the
next. These examples do not: CI and the apply script reject floating tags.

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

`blueprint.yaml` names each Component by its file, `componentRef:
./component-web.yaml`, and every `component*.yaml` must be named by a node.
`scripts/musher-apply.sh` publishes each file, then replaces the file name with
the published id and adds `revision`, because that is how the API names a
Component. In your library a Component is named after the Blueprint's slug and
its file: `component.yaml` is `<slug>`, `component-web.yaml` is `<slug>-web`.

A Component built from the example's Dockerfile uses the image
`this-dockerfile.invalid/<example>`. It is a valid image reference, so the
document validates as written; the apply script replaces it with the image you
pushed, and CI's smoke test with the image it built. `.invalid` never resolves,
so a document applied any other way fails rather than pulling a stranger's
image.

## Checks

CI runs all of these. Run them locally before opening a pull request — they
need `shellcheck`, `check-jsonschema`, `jq`, mikefarah's `yq`, Docker, and
Python 3 with `jsonschema`:

```bash
shellcheck --shell=sh scripts/*.sh scripts/*/*.sh
sh scripts/pins/verify.sh             # vendored contracts match their checksums
sh scripts/check/specs.sh             # every document against the pinned schemas
python3 scripts/check/api-routes.py   # every API call against the pinned OpenAPI
python3 scripts/check/contract-test.py  # the apply script against a fake API that enforces it
for d in */; do [ -f "$d/Dockerfile" ] || continue
  docker build -q -t "musher-examples/${d%/}:ci" "$d" && sh scripts/ci/smoke.sh "${d%/}"; done
```

What each one catches:

| Check | Fails when |
|---|---|
| `pins/verify.sh` | a vendored schema or OpenAPI file was edited by hand, or bumped without `pins.json` |
| `check/specs.sh` | a document does not validate against the pinned schema of its family; a node names a file that does not exist, or a component file is named by no node; an image tag floats |
| `check/api-routes.py` | `musher-apply.sh` or a README `curl`s a method and path the pinned OpenAPI does not have |
| `check/contract-test.py` | a request the script sends — query, body, or the document inside it — does not validate against the pinned OpenAPI, or a re-run is not idempotent |
| `ci/smoke.sh` | the image does not start, or does not answer its readiness probe with its inputs wired as Musher would wire them |

None of these reaches the server-side rules (an unbound required input, a
public endpoint without a probe), which run when a document is published.
Verify an example end to end before submitting it: build, push, apply, and
open the URL. "It should work" is not a check.

## Bumping the pins

[`pins/pins.json`](./pins/pins.json) pins two contracts, and
[`scripts/pins/update.sh`](./scripts/pins/update.sh) is the only way to change
either: it re-vendors the file and records its checksum.

| Pin | What it is | Where it comes from |
|---|---|---|
| `specifications.component`, `specifications.blueprint` | the JSON Schema of one exact release of each family | `https://specifications.musher.dev/<family>/v<version>/<family>.schema.json`, verified against the `.sha256` published beside it |
| `openapi` | the public API's OpenAPI description | `https://api.musher.dev/openapi.json`, or, for Musher maintainers, `contracts/openapi/public.json` in platform-api at a commit |

They are vendored rather than fetched in CI so that a pull request is checked
against exactly what it was written against, offline, and a bump shows up as a
diff a reviewer can read. An exact specification release never changes, so its
checksum can be checked against the specifications project's own ledger.

```bash
# A new specification release (see https://specifications.musher.dev/component/versions.json)
sh scripts/pins/update.sh specifications 2.2.0

# The OpenAPI description, from the published API
sh scripts/pins/update.sh openapi
```

Then run the checks above and fix what they report — documents, comments, the
script, the README `curl` paths — in the same pull request as the bump. A
major version (v3) is a migration, not a bump: each family's `spec.md` has a
"Migration from v2" section, and the modelines at the top of every document
name the major version.

The [Upstream drift](./.github/workflows/upstream.yml) workflow runs
[`scripts/check/upstream.sh`](./scripts/check/upstream.sh) every Monday. It
fails when a newer specification release is out, or when the live API no
longer has a route the examples call or no longer accepts what the script
sends, and its error names the command to run.

## Style

Prose is second person and active. Use the platform's own vocabulary —
Component, Blueprint, Deployment, Instance, Volume, Organization — as defined in
the [glossary](https://docs.musher.dev/glossary). Say "organization", never
"workspace".

## License

Contributions are accepted under [Apache-2.0](./LICENSE).
