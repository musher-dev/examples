## What this changes

<!-- One or two sentences. If it adds an example, say which single idea it teaches. -->

## Checklist

<!-- The full bar is in CONTRIBUTING.md. -->

- [ ] I deployed this end to end — build, push, apply, open the URL — not just built it
- [ ] The base image is pinned by digest and the container runs as a non-root user
- [ ] The image tag is a real version (a floating tag is rejected at publish)
- [ ] A public `SERVICE` declares a readiness probe, and the probe is honest
- [ ] The spec comments explain *why*, not what
- [ ] `shellcheck scripts/*.sh` passes

## For a new example

- [ ] It adds exactly one idea to the example before it
- [ ] Its README follows the house shape, including the `curl`-by-`curl` details block
- [ ] It is added to the ladder table in the root README
