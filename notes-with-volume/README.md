# notes-with-volume

A tiny notes API whose data survives the container being replaced.

**Teaches:** `volumes` claims · `mountPath` · `READ_WRITE_ONCE` vs
`READ_WRITE_MANY` · why a readiness probe should check its storage.

**Assumes** you have been through [`hello-http`](../hello-http).

## The idea

Container filesystems are disposable. Everything written inside a container is
gone when that container is replaced — which happens on every redeploy, every
restart, and whenever an instance moves to a different machine.

A **Volume** is the exception. Declare a claim on the Component and Musher
provisions real storage and mounts it at `mountPath`. Write there, and it stays.

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

## What the spec says

In [`musher/component.yaml`](./musher/component.yaml):

- **Storage is declared on the Component, not the Blueprint.** The Blueprint
  chooses how much compute each node gets; the Component knows what the workload
  needs to keep. The Blueprint echoes the claim but cannot change it.
- **`accessMode: READ_WRITE_ONCE`** gives this node its own block volume,
  attached to one replica at a time — which is why this example deploys with
  `replicas: 1`. `READ_WRITE_MANY` is the shared-filesystem alternative that
  every replica can mount at once. Reach for RWX when replicas must see the same
  *files*; reach for a database when they must agree on the same *records*.
- **`sizeGib: 1`** is the initial size. Size for what the workload will hold,
  not for what it holds today.

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

- **Scale to two replicas** and watch what happens. With `READ_WRITE_ONCE` the
  second replica cannot attach the same volume — this is the constraint the
  access mode exists to express, and meeting it deliberately is cheaper than
  meeting it in production.
- **Switch to `READ_WRITE_MANY`**, redeploy with `replicas: 2`, and post notes
  through both. Then look closely: two writers appending to one file with no
  coordination is exactly the race the in-process lock cannot protect you from.
- **Add a second volume** for uploads at a different `mountPath`. A Component
  may claim more than one.
- **Delete the deployment** and read the volume's lifecycle in the console
  before you confirm.

## Next

[`counter-with-cache`](../counter-with-cache) — two components, wired together.
