# hello-http

One HTTP service with a public URL. This is the whole Musher loop — build an
image, describe it as a Component, compose it into a Blueprint, deploy — with
nothing else in the way.

**Teaches:** the `SERVICE` component kind · a public endpoint · a readiness
probe · per-node compute.

**Time:** about ten minutes, most of it waiting for the image to push.

## The app

Two routes and no dependencies beyond Python's standard library
([`src/app.py`](./src/app.py)):

| Route | Purpose |
|---|---|
| `GET /` | Returns a greeting. What a visitor sees. |
| `GET /healthz` | Returns `{"status":"ok"}`. What Musher's readiness probe polls. |

It handles `SIGTERM` by draining rather than dropping connections, which is what
makes a redeploy invisible to whoever is mid-request.

## Before you start

```bash
export MUSHER_API_KEY="mush_..."   # Console → API Keys
export MUSHER_ORG_ID="..."         # your organization id
export IMAGE_REF="ghcr.io/YOUR-USERNAME/hello-http:0.1.0"
```

## 1. Build and push

```bash
docker build -t "$IMAGE_REF" .
docker push "$IMAGE_REF"
```

If the push 401s, authenticate first — for GHCR that is
`echo $GITHUB_TOKEN | docker login ghcr.io -u YOUR-USERNAME --password-stdin`,
with a token carrying `write:packages`.

Packages you push to GHCR are **private by default**. Either make it public in
the package settings, or register a
[registry credential](https://docs.musher.dev/tundra/registries) for `ghcr.io`
in **Console → Configuration → Registry Credentials** — Musher matches it by
host, so `component.yaml` does not change either way.

Tag with a real version. `:latest` builds fine but is rejected when you publish
the Component, and the error would otherwise arrive two steps later than the
mistake.

## 2. Deploy

```bash
../scripts/musher-apply.sh . "$IMAGE_REF" my-hello
```

Add `DRY_RUN=1` to print the exact request bodies and change nothing.

<details>
<summary>Or do it by hand, one request at a time</summary>

The script is a convenience, not a dependency. Here is every call it makes.

**Draft the Component.** `envsubst` fills in `${IMAGE_REF}`; `yq` strips the
`specVersion`/`kind` envelope, which the create endpoint does not take.

```bash
COMPONENT=$(envsubst < musher/component.yaml \
  | yq -o=json '{"metadata": .metadata, "spec": .spec}' \
  | curl -fsS -X POST "https://api.musher.dev/v1/organizations/$MUSHER_ORG_ID/components" \
      -H "Authorization: Bearer $MUSHER_API_KEY" \
      -H "Content-Type: application/json" --data @-)

COMPONENT_ID=$(jq -r '.metadata.id' <<<"$COMPONENT")
COMPONENT_VERSION=$(jq -r '.metadata.version' <<<"$COMPONENT")
```

**Publish it.** A draft can be edited; a published version cannot, which is what
makes it safe for a Blueprint to pin.

```bash
curl -fsS -X POST "https://api.musher.dev/v1/components/$COMPONENT_ID:publish" \
  -H "Authorization: Bearer $MUSHER_API_KEY"
```

**Compose the Blueprint**, substituting the id and version you just got.

```bash
BLUEPRINT=$(HELLO_HTTP_COMPONENT_ID="$COMPONENT_ID" \
  HELLO_HTTP_COMPONENT_VERSION="$COMPONENT_VERSION" \
  envsubst < musher/blueprint.yaml \
  | yq -o=json '{"metadata": .metadata, "spec": .spec}' \
  | curl -fsS -X POST "https://api.musher.dev/v1/organizations/$MUSHER_ORG_ID/blueprints" \
      -H "Authorization: Bearer $MUSHER_API_KEY" \
      -H "Content-Type: application/json" --data @-)

BLUEPRINT_ID=$(jq -r '.metadata.id' <<<"$BLUEPRINT")

curl -fsS -X POST "https://api.musher.dev/v1/blueprints/$BLUEPRINT_ID:publish" \
  -H "Authorization: Bearer $MUSHER_API_KEY"
```

**Deploy.**

```bash
curl -fsS -X POST \
  "https://api.musher.dev/v1/organizations/$MUSHER_ORG_ID/deployments:deployBlueprint" \
  -H "Authorization: Bearer $MUSHER_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"blueprintId\":\"$BLUEPRINT_ID\",\"userAssignedName\":\"my-hello\",\"replicas\":1}"
```

</details>

## 3. Verify

Watch it come up:

```bash
curl -fsS -H "Authorization: Bearer $MUSHER_API_KEY" \
  "https://api.musher.dev/v1/deployments/$DEPLOYMENT_ID" | jq '.status'
```

Then fetch its URL and call it:

```bash
URL=$(curl -fsS -H "Authorization: Bearer $MUSHER_API_KEY" \
  "https://api.musher.dev/v1/organizations/$MUSHER_ORG_ID/deployments/$DEPLOYMENT_ID/endpoints" \
  | jq -r '.data[0].publicUrl')

curl -fsS "$URL"
# {"message": "Hello from Musher"}
```

You can watch the same thing at
`https://console.musher.dev/deployments/$DEPLOYMENT_ID`.

## What the specs say

[`musher/component.yaml`](./musher/component.yaml) — three things are worth
noticing:

- **`protocol` and `visibility` are required.** They have domain defaults but no
  wire defaults, so omitting either is a `422`.
- **`health.readiness` is mandatory here.** A `SERVICE` with a `PUBLIC` endpoint
  must declare one. A `PRIVATE`-only service need not — see the redis component
  in `counter-with-cache`.
- **`metadata.version` is omitted on purpose**, so Musher allocates the next
  version in the lineage. Re-applying after an edit gives you v2 instead of a
  conflict, and v1 keeps serving until you deploy v2.

[`musher/blueprint.yaml`](./musher/blueprint.yaml) — the node name `web` becomes
the leading label of the deployed hostname, so it has to be a DNS label. Compute
is bound here rather than on the Component, so the same Component can run small
in one Blueprint and large in another.

## Hack on it

- **Change the greeting** without rebuilding: the app reads `GREETING` from the
  environment. Adding a `USER` input to the contract turns that into a field on
  the deploy form — that is what `configurable-greeter` does next.
- **Break the probe** on purpose. Point `readiness.path` at `/nope` and redeploy;
  the instance never becomes ready and no traffic reaches it. This is the
  failure mode the probe exists to cause, on purpose, instead of serving 502s.
- **Scale out.** Pass `"replicas": 3` when you deploy.
- **Make it private.** Flip `visibility` to `PRIVATE` and the endpoint leaves the
  public internet, reachable only from other components in the same app.

## Next

`configurable-greeter` — the same service, with a value the deployer supplies
and a secret the platform generates.
