# notes-with-volume

A tiny notes API whose data survives the container being replaced.

**Teaches:** `volumes` claims · `mountPath` · sizing in the Blueprint ·
shared vs single-attach volumes · why a readiness probe should check its
storage.

**Assumes** you have been through [`hello-http`](../hello-http).

## The idea

Container filesystems are disposable. Everything written inside a container is
gone when that container is replaced — which happens on every redeploy, every
restart, and whenever an instance moves to a different machine.

A **Volume** is the exception. Declare a claim on the Component, allocate it a
size in the Blueprint, and Musher provisions real storage and mounts it at
`mountPath`. Write there, and it stays.

This app appends notes to `/data/notes.jsonl`. That is the only durable path in
the container.

## Run it

```bash
export IMAGE_REF="ghcr.io/YOUR-USERNAME/notes-with-volume:0.1.0"
docker build -t "$IMAGE_REF" . && docker push "$IMAGE_REF"

../scripts/musher-apply.sh . "$IMAGE_REF" my-notes
```

## Verify it actually persists

Write two notes, then force the container to be replaced and confirm they are
still there:

```bash
curl -fsS -X POST "$URL/notes" -d '{"text":"survives restart?"}'
curl -fsS -X POST "$URL/notes" -d '{"text":"second note"}'
curl -fsS "$URL/notes" | jq '.count'   # 2

curl -fsS -X POST -H "Authorization: Bearer $MUSHER_API_KEY" \
  -H "Content-Type: application/json" -d '{}' \
  "https://api.musher.dev/v1/deployments/$DEPLOYMENT_ID:restart"

# once it is running again
curl -fsS "$URL/notes" | jq '.count'   # still 2
```

You can prove the same thing locally in about twenty seconds, which is worth
doing once so the behaviour is concrete rather than asserted:

```bash
docker build -t notes:local .
docker run -d --name notes -p 8080:8080 -v notes-data:/data notes:local
curl -fsS -X POST localhost:8080/notes -d '{"text":"hello"}'
docker rm -f notes                                    # destroy the container
docker run -d --name notes -p 8080:8080 -v notes-data:/data notes:local
curl -fsS localhost:8080/notes | jq '.count'          # 1 — the volume outlived it
docker rm -f notes && docker volume rm notes-data
```

Now drop `-v notes-data:/data` and repeat. The count resets to zero, because
without the volume `/data` is just another disposable directory.

## What the specs say

In [`musher/component.yaml`](./musher/component.yaml):

- **The claim is declared on the Component.** It knows what the workload needs
  to keep and where it writes it: `mountPath`, and `minSizeGiB`, the smallest
  allocation it can run with.
- **`shared: false`** (the default) gives this node its own volume, mounted
  into one replica at a time, including while it is replaced — which is why
  this example deploys with `replicas: 1`. `shared: true` is the alternative
  every replica mounts at once. Reach for it when replicas must see the same
  *files*; reach for a database when they must agree on the same *records*.

In [`musher/blueprint.yaml`](./musher/blueprint.yaml):

- **The size is allocated per node**, like compute: `volumes.data.sizeGiB: 1`.
  Every volume the Component declares must be allocated, at or above its
  minimum; there is no implicit default size. Size for what the workload will
  hold, not for what it holds today.

Two things in [`Dockerfile`](./Dockerfile) and [`src/app.py`](./src/app.py) are
easy to get wrong and painful to debug:

- **`/data` is created and chowned at build time.** Musher mounts an empty
  volume on first deploy, and a container running as a non-root user cannot
  chown a mount point it does not already own. Skip this and the app starts,
  then fails its first write.
- **Writes are `flush()` + `os.fsync()`.** Without the fsync the note is in the
  OS page cache, not on the volume, and an abrupt restart loses it. Durability
  you did not ask for is not durability you have.

The readiness probe checks `/data` is writable rather than just returning 200.
A volume that failed to mount should take the instance out of rotation, not
serve errors to users.

## Hack on it

- **Deploy with two replicas** and read the refusal. A non-shared volume runs
  one replica at a time, so the platform says no before anything starts — the
  constraint `shared` exists to express, met deliberately rather than in
  production.
- **Switch to `shared: true`**, redeploy with `replicas: 2`, and post notes
  through both. Then look closely: two writers appending to one file with no
  coordination is exactly the race the in-process lock cannot protect you from.
- **Add a second volume** for uploads at a different `mountPath`. A Component
  may claim more than one, and the Blueprint allocates each.
- **Delete the deployment** and read the volume's lifecycle in the console
  before you confirm.

## Next

[`counter-with-cache`](../counter-with-cache) — two components, wired together.
