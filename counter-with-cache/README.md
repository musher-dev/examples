# counter-with-cache

A visit counter and the Redis it counts in — two Components, wired together.

**Teaches:** `contract.outputs` · `suppliedBy: CONNECTION` · Blueprint
`connections` · `{{ self.privateAddress.* }}` · `semanticType` · PRIVATE
endpoints · wrapping a public image as a Component.

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
    url ──────────┐               cacheUrl  (suppliedBy: CONNECTION)
                  │                   ▲
                  │  blueprint.yaml   │
                  └───────────────────┘
                     web.connections.cacheUrl = { fromRole: cache, fromOutput: url }
```

What you get from that indirection is worth naming, because it is the entire
reason to do it this way:

- **The image has no address in it.** `REDIS_URL` arrives from the environment.
  Swap the cache for a managed one and nothing rebuilds.
- **The address is per-deployment.** Two deployments of this Blueprint get two
  caches, and neither can see the other's — the resolved hostname contains the
  deployment's own name.
- **A missing wire is caught at publish, not at 3am.** `cacheUrl` is required
  and has no default; a Blueprint that leaves it unwired does not publish.

## Run it

```bash
export IMAGE_REF="ghcr.io/YOUR-USERNAME/counter-with-cache:0.1.0"
docker build -t "$IMAGE_REF" . && docker push "$IMAGE_REF"

../scripts/musher-apply.sh . "$IMAGE_REF" my-counter
```

You build **one** image. The cache is the public `redis:7.4.2-alpine`, wrapped
in a Component that adds what the graph needs to know about it. Every backing
service works this way — there is no separate "add-on" concept to learn.

Then count:

```bash
curl -fsS "$URL"        # {"visits":1,...}
curl -fsS "$URL"        # {"visits":2,...}
```

Scale to two replicas and keep going. The count keeps climbing, and
`servedBy` changes — which is the point of putting state in a cache instead
of in the process.

## What the spec says

**The cache publishes a value, not an address** —
[`musher/component-cache.yaml`](./musher/component-cache.yaml):

```yaml
outputs:
  url:
    schema: { type: STRING, format: CONNECTION_STRING, semanticType: REDIS }
    valueFrom: DECLARED
    value: redis://{{ self.privateAddress.primary }}
```

`{{ self.privateAddress.primary }}` resolves to this node's own mesh address
for the endpoint named `primary`. The `self.*` namespace can only reference the
node's own bindings and addressing — never a value the node received over a
wire. That restriction is what lets Musher resolve every node's outputs *before*
wiring any of them, which in turn is why two services may reference each other
without either one having to come first.

`valueFrom: DECLARED` means this Component authors the value. The alternative,
`DERIVED`, hands the platform the job — a `url` output on a public service
resolves to its public URL with no template at all. Use DECLARED when the value
needs a shape the platform cannot guess, like a scheme prefix.

`semanticType: REDIS` is not decoration. A Redis URL and a Postgres DSN are both
`CONNECTION_STRING`s and are not interchangeable; the publish gate rejects a
wire whose two ends declare different semantic types.

**The web service declares a need** —
[`musher/component-web.yaml`](./musher/component-web.yaml):

```yaml
inputs:
  cacheUrl:
    schema: { type: STRING, format: CONNECTION_STRING, semanticType: REDIS }
    suppliedBy: CONNECTION
    isRequired: true
    target: { envVarKey: REDIS_URL }
```

`suppliedBy: CONNECTION` is the difference from `configurable-greeter`, where
inputs were `USER` and appeared on the deploy form. Nobody types this one. There
is no `ui` block, and adding one is rejected — a wired input has no form field
to render.

`target.envVarKey` is where the resolved value lands. Omit it and the wire
validates, resolves, and delivers the value nowhere the process can read it.

**The Blueprint connects them** —
[`musher/blueprint.yaml`](./musher/blueprint.yaml):

```yaml
web:
  connections:
    cacheUrl:
      fromRole: cache
      fromOutput: url
```

Connections are anchored on the consumer and keyed by the input they fill, so
the line reads as a sentence: *`cacheUrl` comes from the `cache` node's `url`
output*. One input takes one wire; a second entry for the same key is a
conflict, not an override.

**The readiness probe checks the dependency.** `/healthz` PINGs Redis. An
instance that cannot reach its cache cannot serve a request, so it should not be
in rotation — reporting 200 while every request 503s is precisely what a
readiness probe exists to prevent.

## Hack on it

- **Delete the `connections` block** and try to publish the Blueprint. The
  error names the unwired input. That message is the whole safety argument for
  declaring needs instead of documenting them.
- **Change the cache's `semanticType` to `POSTGRES`** and publish. The wire is
  now type-incompatible and the gate says so — before anything deploys.
- **Point `cacheUrl` at a managed Redis** instead: drop the cache node, change
  the input to `suppliedBy: USER` with a `ui.label`, and it becomes a deploy-form
  field. Same image, same code, different topology.
- **Add a second consumer.** One output can feed many inputs; wire a second node
  to the same `cache.url`.
- **Make the cache public** (`visibility: PUBLIC`) and think about what you just
  did. Then put it back.

## Next

[`queue-worker`](../queue-worker) — a workload with no endpoint at all.
