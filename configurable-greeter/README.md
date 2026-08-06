# configurable-greeter

The same service as `hello-http`, except the deployer chooses part of its
behaviour and the platform mints its secret. One image, many configurations —
no rebuild.

**Teaches:** `contract.inputs` · the deploy form · platform-generated secrets ·
`LITERAL` environment variables.

**Assumes** you have been through [`hello-http`](../hello-http).

## The three kinds of configuration

This example carries one of each, which is the whole point of reading it.

| Value | Declared as | Who decides | When |
|---|---|---|---|
| `BUILD_CHANNEL` | `envVars` `LITERAL` | the Component author | fixed for every deployment |
| `GREETING` | `contract.inputs` · `suppliedBy: USER` | whoever deploys | at deploy time, on the form |
| `ADMIN_TOKEN` | `contract.inputs` · `generator` | nobody — Musher mints it | at deploy time |

All three reach the container the same way: as environment variables. The
difference is who gets to set them, and that difference is the contract.

## Run it

```bash
export IMAGE_REF="ghcr.io/YOUR-USERNAME/configurable-greeter:0.1.0"
docker build -t "$IMAGE_REF" . && docker push "$IMAGE_REF"

../scripts/musher-apply.sh . "$IMAGE_REF" my-greeter
```

The apply script accepts the defaults for every input. To choose a greeting
instead, pass `parameterValues` when you deploy:

```bash
curl -fsS -X POST \
  "https://api.musher.dev/v1/organizations/$MUSHER_ORG_ID/deployments:deployBlueprint" \
  -H "Authorization: Bearer $MUSHER_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{
        \"blueprintId\": \"$BLUEPRINT_ID\",
        \"userAssignedName\": \"my-greeter\",
        \"parameterValues\": {\"greeting\": \"Hej från Musher\"},
        \"replicas\": 1
      }"
```

Note what is *not* in that call: `adminToken`. An input with a `generator` is
minted by the platform, and supplying a value for one is rejected.

## Verify

```bash
curl -fsS "$URL"
# {"message": "Hej från Musher", "channel": "stable"}
```

Read the generated token back. Masked by default:

```bash
curl -fsS -H "Authorization: Bearer $MUSHER_API_KEY" \
  "https://api.musher.dev/v1/deployments/$DEPLOYMENT_ID/env" | jq
```

Plaintext requires the `secrets:reveal` permission, and the access is written to
the audit trail:

```bash
TOKEN=$(curl -fsS -X POST -H "Authorization: Bearer $MUSHER_API_KEY" \
  "https://api.musher.dev/v1/deployments/$DEPLOYMENT_ID/env:reveal" \
  | jq -r '.data[] | select(.key=="ADMIN_TOKEN") | .value')

curl -fsS -H "X-Admin-Token: $TOKEN" "$URL/admin"
```

Without the header, `/admin` returns 401. That path is worth reading in
[`src/app.py`](./src/app.py): it compares with `hmac.compare_digest` rather than
`==`, because a plain comparison returns early on the first wrong character and
leaks the token one byte at a time. And if `ADMIN_TOKEN` is unset it returns 503
rather than allowing the request — a missing secret must never mean "open".

## What the spec says

In [`musher/component.yaml`](./musher/component.yaml):

- **`ui.label` is required for a `USER` input** and forbidden for a `CONNECTION`
  one. The label is what appears on the deploy form, so an input without one has
  no way to be asked for.
- **A sensitive input carries no `default`.** A default would have to be stored
  and echoed back, which is the one thing a secret must not be. Use a
  `generator` instead — `byteLength` is entropy in bytes, and `encoding` is
  `HEX`, `BASE64`, `BASE64URL`, or `ALPHANUMERIC`.
- **`envVars` is an array**, while `inputs`, `outputs`, `endpoints`, and
  `volumes` are maps. That is not an inconsistency to work around: env vars are
  ordered named entries, matching how Kubernetes and ECS model them.

In [`musher/blueprint.yaml`](./musher/blueprint.yaml), `parameters` is empty on
purpose. An empty map means "derive the form from the Components' `USER`
inputs", so `greeting` and `adminToken` appear without being restated. Declare
parameters explicitly only when the Blueprint must say something the Components
cannot — renaming a field, or feeding one value to two nodes.

## Hack on it

- **Add an input** for the channel, so it stops being fixed. Move
  `BUILD_CHANNEL` out of `envVars` and into `contract.inputs` with a `schema.enum`
  of `["stable", "beta"]`; the deploy form renders a select instead of a text
  field, derived from the schema.
- **Make the greeting optional.** Set `isRequired: false` and watch it drop off
  the required section of the form.
- **Rotate the token.** Redeploy and reveal it again — the generator runs per
  deployment, so it is a different value.
- **Try to supply `adminToken`** in `parameterValues` and read the error. Being
  refused is the feature.

## Next

`notes-with-volume` — storage that outlives the container.
