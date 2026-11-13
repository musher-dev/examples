# counter-with-cache

A visit counter and the Redis it counts in — two Components, wired together.

**Teaches:** `contract.outputs` · output templates and
`${{ self.endpoints.* }}` · Blueprint `bindings` from one node to another ·
private endpoints · wrapping a public image as a Component.

**Assumes** you have been through [`configurable-greeter`](../configurable-greeter).

## The idea

Up to here every example has been one workload. Real applications are several,
and the interesting question is how one finds another.

The answer Musher gives is: it does not. The web service declares that it
*needs* a cache URL. The cache declares that it *offers* one. Neither knows
about the other. A third file — the Blueprint — says which offer satisfies
which need, and the platform resolves the address at deploy time and hands it
over as an environment variable.

```
component-cache.yaml          component-web.yaml
  outputs:                      inputs:
    url ──────────┐               cacheUrl  →  REDIS_URL
                  │                   ▲
                  │  blueprint.yaml   │
                  └───────────────────┘
                     web.bindings.cacheUrl = { node: cache, output: url }
```

What you get from that indirection is worth naming, because it is the entire
reason to do it this way:

- **The image has no address in it.** `REDIS_URL` arrives from the environment.
  Swap the cache for a managed one and nothing rebuilds.
- **The address is per-deployment.** Two deployments of this Blueprint get two
  caches, and neither can see the other's — each node's hostname is allocated
  for its own deployment.
- **A missing wire is caught at publish, not at 3am.** `cacheUrl` is required
  and has no default; a Blueprint that binds nothing to it does not publish.

## Run it

```bash
export IMAGE_REF="ghcr.io/YOUR-USERNAME/counter-with-cache:0.1.0"
docker build -t "$IMAGE_REF" . && docker push "$IMAGE_REF"

../scripts/musher-apply.sh . "$IMAGE_REF" my-counter
```

You build **one** image. The cache is the public `redis:7.4.2-alpine`, wrapped
in a Component that adds what the graph needs to know about it. Every backing
service works this way — there is no separate "add-on" concept to learn. The
script publishes the two Components as `counter-with-cache-cache` and
`counter-with-cache-web`, after the Blueprint and their file names.

Then count:

```bash
curl -fsS "$URL"        # {"visits":1,...}
curl -fsS "$URL"        # {"visits":2,...}
```

Scale to two replicas and keep going. The count keeps climbing, and
`servedBy` changes — which is the point of putting state in a cache instead
of in the process.

## What the specs say

**The cache publishes a value, not an address** —
[`musher/component-cache.yaml`](./musher/component-cache.yaml):

```yaml
outputs:
  url:
    description: Mesh-internal Redis URL for sibling nodes in this deployment.
    schema: { type: string }
    presentationHint: CONNECTION_STRING
    from:
      template: redis://${{ self.endpoints.primary.privateAddress }}
```

`${{ self.endpoints.primary.privateAddress }}` resolves to this node's own mesh
`host:port` for the endpoint named `primary`. A template can only reference the
node's own endpoints — never a value the node received over a wire. That
restriction is what lets Musher resolve every node's addresses *before* wiring
any of them, which in turn is why two services may reference each other without
either one having to come first.

A template is one of four origins an output can have. When the value needs no
shape of its own, `from: { endpoint: primary, property: privateAddress }` hands
over the bare `host:port`; a template is for when it needs a scheme prefix, or
a path. `presentationHint` only says how to show the value. Musher checks that
both ends of a wire carry the same logical type — a string here — and nothing
finer: a Redis URL and a Postgres DSN are both strings, so the input's
`description` is what tells a reader which one it wants.

**The web service declares a need** —
[`musher/component-web.yaml`](./musher/component-web.yaml):

```yaml
inputs:
  cacheUrl:
    description: Redis URL this service increments its counter in.
    schema: { type: string }
    presentationHint: CONNECTION_STRING
    target: { envVar: REDIS_URL }
```

Nothing on the input says who supplies it. In `configurable-greeter` the
Blueprint bound inputs to parameters, which put them on the deploy form; here it
binds this one to another node, so nobody types it. The same Component could be
deployed either way.

`target.envVar` is where the resolved value lands. An input with no target that
nothing else reads is refused as unused, so a wire can never resolve to nothing
the process can read.

**The Blueprint connects them** —
[`musher/blueprint.yaml`](./musher/blueprint.yaml):

```yaml
web:
  bindings:
    cacheUrl:
      node: cache
      output: url
```

Bindings are anchored on the consumer and keyed by the input they fill, so the
line reads as a sentence: *`cacheUrl` comes from the `cache` node's `url`
output*. One input takes one binding; a second origin for the same key is a
conflict, not an override.

The cache node has no `exposure`, so its endpoint is private: reachable by
sibling nodes, never from the internet. A cache with a public URL is a cache
someone else is using.

**The readiness probe checks the dependency.** `/healthz` PINGs Redis. An
instance that cannot reach its cache cannot serve a request, so it should not be
in rotation — reporting 200 while every request 503s is precisely what a
readiness probe exists to prevent.

## Hack on it

- **Delete the `bindings` block** and apply again. Publishing the Blueprint
  fails, and the error names the input with no origin. That message is the
  whole safety argument for declaring needs instead of documenting them.
- **Point `cacheUrl` at a managed Redis** instead: drop the cache node, add a
  `cacheUrl` parameter with a `ui.label`, and bind the input to it. It becomes
  a deploy-form field. Same image, same code, different topology.
- **Add a second consumer.** One output can feed many inputs; bind a second
  node to the same `cache` `url`.
- **Expose the cache** (`exposure: { primary: PUBLIC }` on the cache node) and
  notice that nothing stops you: a TCP endpoint gets a public address, and this
  Redis has no password. Think about what you just did. Then put it back.

## Next

[`queue-worker`](../queue-worker) — a workload with no endpoint at all.
