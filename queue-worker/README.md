# queue-worker

An API that accepts work and a worker that does it — with a queue between them.

**Teaches:** `kind: WORKER` · a workload with no endpoint · one output feeding
two consumers · one image running two workloads · why a worker has no readiness
probe.

**Assumes** you have been through [`counter-with-cache`](../counter-with-cache).

## The idea

Not every workload answers requests. A worker consumes a queue, a batch job
processes a file, a scheduler wakes up on the hour. None of them has a URL, and
a platform that assumes everything is a web service makes them awkward.

`kind: WORKER` says it plainly: long-running like a `SERVICE`, but nothing
routes to it. Musher enforces the second half — declare an endpoint on a WORKER
and the Component is rejected, because there would be nothing honest to do with
it.

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

Then scale the worker to three replicas and submit ten jobs. They spread across
the workers with no coordination, because `RPOP` is atomic — the queue is what
makes the workers interchangeable.

## What the spec says

**A WORKER declares no endpoint and no probe** —
[`musher/component-worker.yaml`](./musher/component-worker.yaml):

```yaml
workload:
  kind: WORKER
  source: { type: IMAGE, ref: ${IMAGE_REF} }
  envVars:
    - { key: ROLE, value: { type: LITERAL, value: worker } }
```

No `endpoints`. No `health`. Readiness gates *routing*, and nothing routes here,
so a readiness probe would be answering a question nobody asked. What tells you
a worker is healthy is its logs and whether the queue depth is going down.

**One output, two consumers** —
[`musher/blueprint.yaml`](./musher/blueprint.yaml). Both `api` and `worker`
wire `queueUrl` from `queue.url`. An output is not consumed by being wired; it
satisfies as many inputs as ask for it, and each consumer receives the same
resolved address.

**Two Components, one image.** `api` and `worker` point at the same
`${IMAGE_REF}` and differ by a `ROLE` literal. That is a choice made for this
example's build loop, not a platform requirement — two Dockerfiles and two
images work identically. What *is* platform-shaped is that `kind` differs, and
`kind` is what determines whether the workload can have an endpoint at all.

**The API returns 202, not 200.** The job is queued, not finished. An async API
that reports success before the work happens is one that will be believed.

## Hack on it

- **Add an endpoint to the worker** and try to create the Component. The
  rejection is the point: the constraint is in the model, not in a style guide.
- **Kill the worker** (scale it to zero) and submit jobs. They queue up. Scale
  it back and watch them drain — which is the property you bought by putting a
  queue in the middle instead of calling the worker directly.
- **Make it a `CRON`** instead: change `kind`, add `schedule.cron` and a
  `command`, and it becomes a scheduled batch rather than a poller.
- **Give the worker its own image.** Split the Dockerfile in two and drop the
  `ROLE` variable. Nothing about the Blueprint changes, which is the point.
- **Replace `RPOP` polling with `BRPOP`.** It is a one-line protocol change and
  an idle queue stops costing anything.

## Next

You have the whole model: Components, Blueprints, inputs, outputs, connections,
volumes, and the two runtime shapes. Go build yours — and if you build something
worth copying, [CONTRIBUTING.md](../CONTRIBUTING.md) says how to add it here.
