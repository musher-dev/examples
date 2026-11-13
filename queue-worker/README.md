# queue-worker

An API that accepts work and a worker that does it — with a queue between them.

**Teaches:** `type: WORKER` · a workload with no endpoint · one output feeding
two consumers · one image running two workloads · why a worker has no readiness
probe.

**Assumes** you have been through [`counter-with-cache`](../counter-with-cache).

> [!WARNING]
> **Known issue: the worker is stopped about 15 seconds after it starts.** The
> platform currently treats a `WORKER` that declares no endpoint as a workload
> that failed to bind its port, and kills it (tracked as
> musher-dev/platform-api#1440; a fix is in progress). Until it ships, jobs
> queue up but are processed only in the seconds after each restart. The
> documents here are what a worker *should* declare, so they will not change
> when the fix lands — please do not work around it by adding an endpoint the
> worker does not serve.

## The idea

Not every workload answers requests. A worker consumes a queue, a batch job
processes a file, a scheduler wakes up on the hour. None of them has a URL, and
a platform that assumes everything is a web service makes them awkward.

`type: WORKER` says it plainly: long-running like a `SERVICE`, but not
request-driven. A worker *may* declare endpoints — a private health port for
the platform to probe, or a port its sibling nodes call — but never a public
one; a Blueprint that exposes a `WORKER` endpoint is refused. This worker needs
none, so it declares none.

```
        POST /jobs                    RPOP
  you ──────────────► api ──LPUSH──► queue ──────────► worker
        GET /jobs/id ◄─── GET ────────┘                  │
                                       ▲                 │
                                       └───── SET ───────┘
```

Three nodes, two wires, one image.

## Run it

```bash
export IMAGE_REF="ghcr.io/YOUR-USERNAME/queue-worker:0.1.0"
docker build -t "$IMAGE_REF" . && docker push "$IMAGE_REF"

../scripts/musher-apply.sh . "$IMAGE_REF" my-queue
```

Submit work and collect the result:

```bash
ID=$(curl -fsS -X POST "$URL/jobs" -d '{"text":"hello"}' | jq -r .id)
curl -fsS "$URL/jobs/$ID"    # {"status":"pending"}  — then, a moment later:
curl -fsS "$URL/jobs/$ID"    # {"status":"done","result":"HELLO"}
```

Then scale to three replicas and submit ten jobs. They spread across the
workers with no coordination, because `RPOP` is atomic — the queue is what
makes the workers interchangeable.

## What the specs say

**A WORKER that declares no endpoint and no probe** —
[`musher/component-worker.yaml`](./musher/component-worker.yaml):

```yaml
spec:
  type: WORKER
  workload:
    source:
      image: this-dockerfile.invalid/queue-worker
```

No `endpoints`, so no `health`: a probe is an HTTP request to a declared
endpoint, and readiness gates *routing*, which nothing does here. What tells you
a worker is healthy is its logs and whether the queue depth is going down. A
worker that can answer a health check would declare a private endpoint and a
probe on it — that is a real endpoint, not a workaround.

**One output, two consumers** —
[`musher/blueprint.yaml`](./musher/blueprint.yaml). Both `api` and `worker`
bind `queueUrl` to `queue`'s `url`. An output is not consumed by being wired; it
satisfies as many inputs as ask for it, and each consumer receives the same
resolved address. The worker node still gets `compute`: it runs, so it needs
somewhere to run.

**Two Components, one image.** `api` and `worker` use the same image and differ
by a `role` input whose default is `api` in one and `worker` in the other (each
`enum` allows only its own, so no Blueprint can bind the wrong one). That is a
choice made for this example's build loop, not a platform requirement — two
Dockerfiles and two images work identically. What *is* platform-shaped is that
`type` differs, and `type` is what decides whether a workload may be public.

**The API returns 202, not 200.** The job is queued, not finished. An async API
that reports success before the work happens is one that will be believed.

## Hack on it

- **Expose the worker.** Give it an endpoint, add `exposure: { <name>: PUBLIC }`
  to its node, and try to publish the Blueprint. The refusal is the point: the
  constraint is in the model, not in a style guide.
- **Kill the worker** (remove its node) and submit jobs. They queue up. Put it
  back and watch them drain — which is the property you bought by putting a
  queue in the middle instead of calling the worker directly.
- **Make it a scheduled `JOB`** instead: change `type`, add a
  `schedule: { cron: "*/5 * * * *" }` and a `command`, and it becomes a batch
  that drains the queue every five minutes rather than a poller.
- **Give the worker its own image.** Split the Dockerfile in two and drop the
  `role` input. Nothing about the Blueprint changes, which is the point.
- **Replace `RPOP` polling with `BRPOP`.** It is a one-line protocol change and
  an idle queue stops costing anything.

## Next

You have the whole model: Components, Blueprints, inputs, outputs, bindings,
parameters, volumes, and the two runtime shapes. Go build yours — and if you
build something worth copying, [CONTRIBUTING.md](../CONTRIBUTING.md) says how to
add it here.
