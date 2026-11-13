# hello-http

One HTTP service with a public URL. This is the whole Musher loop — build an
image, describe it as a Component, compose it into a Blueprint, deploy — with
nothing else in the way.

**Teaches:** the `SERVICE` component type · an endpoint the Blueprint makes
public · a readiness probe · per-node compute.

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

Tag with a real version. Musher would accept `:latest`, but then the same
Component revision could run different code tomorrow and nobody could say
which; the apply script refuses a floating tag for that reason.

## 2. Deploy

```bash
../scripts/musher-apply.sh . "$IMAGE_REF" my-hello
```

Add `DRY_RUN=1` to print the exact request bodies and change nothing.

<details>
<summary>Or do it by hand, one request at a time</summary>

The script is a convenience, not a dependency. Here is every call it makes the
first time; a later run adds revisions instead, as the note at the end says.
Drop `-f` from a `curl` to see the API's error document when a call is refused.

**Draft the Component.** `yq` turns the YAML into JSON, and `jq` swaps the
placeholder image for yours and wraps it as the create endpoint expects: the
document, plus the `slug` that names it in your library.

```bash
COMPONENT=$(yq -o=json musher/component.yaml \
  | jq --arg image "$IMAGE_REF" \
      '{slug: "hello-http", document: (.spec.workload.source.image = $image)}' \
  | curl -fsS -X POST "https://api.musher.dev/v1/organizations/$MUSHER_ORG_ID/components" \
      -H "Authorization: Bearer $MUSHER_API_KEY" \
      -H "Content-Type: application/json" --data @-)

COMPONENT_ID=$(echo "$COMPONENT" | jq -r '.componentId')
COMPONENT_REVISION=$(echo "$COMPONENT" | jq -r '.revision')
```

**Publish it.** A draft can be edited; a published revision cannot, which is
what makes it safe for a Blueprint to pin. Publishing is also where every rule
is checked, so this is the call that tells you what is wrong with a document.

```bash
curl -fsS -X POST \
  "https://api.musher.dev/v1/components/$COMPONENT_ID/versions/$COMPONENT_REVISION:publish" \
  -H "Authorization: Bearer $MUSHER_API_KEY"
```

**Compose the Blueprint.** `blueprint.yaml` names the Component by its file,
`./component.yaml`; the API names it by id and revision. Swap one for the
other, then publish.

```bash
BLUEPRINT=$(yq -o=json musher/blueprint.yaml \
  | jq --arg id "$COMPONENT_ID" --argjson rev "$COMPONENT_REVISION" \
      '{slug: .metadata.slug,
        document: (.spec.nodes.web.componentRef = $id | .spec.nodes.web.revision = $rev)}' \
  | curl -fsS -X POST "https://api.musher.dev/v1/organizations/$MUSHER_ORG_ID/blueprints" \
      -H "Authorization: Bearer $MUSHER_API_KEY" \
      -H "Content-Type: application/json" --data @-)

BLUEPRINT_ID=$(echo "$BLUEPRINT" | jq -r '.blueprintId')
BLUEPRINT_REVISION=$(echo "$BLUEPRINT" | jq -r '.revision')

curl -fsS -X POST \
  "https://api.musher.dev/v1/blueprints/$BLUEPRINT_ID/versions/$BLUEPRINT_REVISION:publish" \
  -H "Authorization: Bearer $MUSHER_API_KEY"
```

**Deploy** that revision under a name of your choosing.

```bash
DEPLOYMENT_ID=$(curl -fsS -X POST \
  "https://api.musher.dev/v1/organizations/$MUSHER_ORG_ID/deployments:deployBlueprint" \
  -H "Authorization: Bearer $MUSHER_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"blueprintId\": \"$BLUEPRINT_ID\", \"revision\": $BLUEPRINT_REVISION, \"name\": \"my-hello\"}" \
  | jq -r '.metadata.id')
```

**The second time round**, the slug is taken: a changed document becomes a new
revision of the same Component, sent to `POST /v1/components/{id}/versions`
with `metadata.revision` raised, then published the same way. A deployment
moves to a new Blueprint revision with `POST /v1/deployments/{id}:update` and
`{"revision": N}`. That is all the script adds.

</details>

## 3. Verify

If you used the script, look the deployment up by its name:

```bash
DEPLOYMENT_ID=$(curl -fsS -H "Authorization: Bearer $MUSHER_API_KEY" \
  "https://api.musher.dev/v1/organizations/$MUSHER_ORG_ID/deployments:byName?name=my-hello" \
  | jq -r '.metadata.id')
```

Watch it come up. `ACTIVE` means it is running:

```bash
curl -fsS -H "Authorization: Bearer $MUSHER_API_KEY" \
  "https://api.musher.dev/v1/deployments/$DEPLOYMENT_ID" | jq -r '.status.phase'
```

Then fetch its URL and call it:

```bash
URL=$(curl -fsS -H "Authorization: Bearer $MUSHER_API_KEY" \
  "https://api.musher.dev/v1/organizations/$MUSHER_ORG_ID/deployments/$DEPLOYMENT_ID/endpoints" \
  | jq -r '.data[] | select(.visibility == "PUBLIC") | "\(.publicScheme)://\(.publicHostname)"')

curl -fsS "$URL"
# {"message": "Hello from Musher"}
```

You can watch the same thing at
`https://console.musher.dev/deployments/$DEPLOYMENT_ID`.

## What the specs say

[`musher/component.yaml`](./musher/component.yaml) — three things are worth
noticing:

- **`protocol` is required**, and there is no default. `targetPort` is the
  port the process listens on; the public port is the platform's to allocate.
- **The Component never says "public".** It declares endpoints; the Blueprint
  decides which are exposed. That is why the readiness probe is here: a
  Blueprint that exposes this endpoint `PUBLIC` is refused unless the
  Component declares one. A private-only service need not — see the Redis
  component in `counter-with-cache`.
- **`metadata.revision` orders publications.** Each must be higher than the
  last, so the apply script fills in the next free one: re-applying after an
  edit gives you revision 2, and revision 1 keeps serving until you deploy
  revision 2.

[`musher/blueprint.yaml`](./musher/blueprint.yaml) — the node name `web` becomes
the leading label of the deployed hostname, so it has to be a DNS label. Compute
and exposure are bound here rather than on the Component, so the same Component
can run small and private in one Blueprint and large and public in another.
`componentRef: ./component.yaml` is how a Blueprint names a Component beside it;
the API names it by id and revision, which is the one substitution the apply
script makes.

## Hack on it

- **Change the greeting** without rebuilding: the app reads `GREETING` from the
  environment. Adding an input to the contract, and a parameter for it to the
  Blueprint, turns that into a field on the deploy form — that is what
  `configurable-greeter` does next.
- **Break the probe** on purpose. Point `readiness.path` at `/nope` and redeploy;
  the instance never becomes ready and no traffic reaches it. This is the
  failure mode the probe exists to cause, on purpose, instead of serving 502s.
- **Scale out.** Pass `"replicas": 3` when you deploy.
- **Make it private.** Delete the `exposure` block from the Blueprint and the
  endpoint leaves the public internet, reachable only from other nodes in the
  same deployment.

## Next

`configurable-greeter` — the same service, with a value the deployer supplies
and a secret the platform generates.
