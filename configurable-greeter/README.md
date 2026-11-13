# configurable-greeter

The same service as `hello-http`, except the deployer chooses part of its
behaviour and the platform mints its secret. One image, many configurations —
no rebuild.

**Teaches:** `contract.inputs` · input defaults · Blueprint `parameters` and
the deploy form · generated secrets.

**Assumes** you have been through [`hello-http`](../hello-http).

## The three kinds of configuration

This example carries one of each, which is the whole point of reading it.

| Value | Component input | Blueprint | Who decides | When |
|---|---|---|---|---|
| `BUILD_CHANNEL` | `buildChannel`, with a `default` | not bound | the Component author | fixed, unless a Blueprint binds it |
| `GREETING` | `greeting` | bound to a parameter with `ui` | whoever deploys | at deploy time, on the form |
| `ADMIN_TOKEN` | `adminToken`, `sensitive` | bound to a `generator` parameter | nobody — Musher mints it | at deploy time |

All three reach the container the same way: an input's `target.envVar` is the
only thing that writes the environment. The Component says *what* it needs; the
Blueprint says *where each value comes from*. That split is the contract.

## Run it

```bash
export IMAGE_REF="ghcr.io/YOUR-USERNAME/configurable-greeter:0.1.0"
docker build -t "$IMAGE_REF" . && docker push "$IMAGE_REF"

../scripts/musher-apply.sh . "$IMAGE_REF" my-greeter
```

The apply script submits no parameters, so the greeting takes its default. To
see the form a deployer would get, look the Blueprint up by its slug and read
the form of its published revision:

```bash
BLUEPRINT=$(curl -fsS -H "Authorization: Bearer $MUSHER_API_KEY" \
  "https://api.musher.dev/v1/organizations/$MUSHER_ORG_ID/blueprints?slug=configurable-greeter")
BLUEPRINT_ID=$(echo "$BLUEPRINT" | jq -r '.data[0].id')
BLUEPRINT_REVISION=$(echo "$BLUEPRINT" | jq -r '.data[0].latestPublishedVersion.revision')

curl -fsS -H "Authorization: Bearer $MUSHER_API_KEY" \
  "https://api.musher.dev/v1/blueprints/$BLUEPRINT_ID/versions/$BLUEPRINT_REVISION/deploy-form" | jq
```

It has one field, `greeting`. To choose one yourself, deploy that revision with
`parameters`:

```bash
curl -fsS -X POST \
  "https://api.musher.dev/v1/organizations/$MUSHER_ORG_ID/deployments:deployBlueprint" \
  -H "Authorization: Bearer $MUSHER_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{
        \"blueprintId\": \"$BLUEPRINT_ID\",
        \"revision\": $BLUEPRINT_REVISION,
        \"name\": \"my-swedish-greeter\",
        \"parameters\": {\"greeting\": \"Hej från Musher\"}
      }"
```

Note what is *not* in that call: `adminToken`. A generated parameter is minted
by the platform, and submitting a value for one is refused.

## Verify

Find `DEPLOYMENT_ID` and `URL` as in [`hello-http`](../hello-http#3-verify),
for whichever deployment you want to look at.

```bash
curl -fsS "$URL"
# {"message": "Hej från Musher", "channel": "stable"}
```

Read the environment back. With an API key, sensitive values come back masked:

```bash
curl -fsS -H "Authorization: Bearer $MUSHER_API_KEY" \
  "https://api.musher.dev/v1/deployments/$DEPLOYMENT_ID/env" \
  | jq '.nodes[].variables[] | {key, value, isSensitive}'
```

Revealing the token in plaintext needs a person, not a key: open the deployment
in the console and reveal **Admin token**. That requires the `secrets:reveal`
permission, and the access is written to the audit trail under your name. It
can be revealed at all only because the Blueprint gives the generated
parameter a `ui` label; without one, the value is the workload's alone. Paste
it into `TOKEN`:

```bash
curl -fsS -H "X-Admin-Token: $TOKEN" "$URL/admin"
```

Without the header, `/admin` returns 401. That path is worth reading in
[`src/app.py`](./src/app.py): it compares with `hmac.compare_digest` rather than
`==`, because a plain comparison returns early on the first wrong character and
leaks the token one byte at a time. And if `ADMIN_TOKEN` is unset it returns 503
rather than allowing the request — a missing secret must never mean "open".

## What the specs say

In [`musher/component.yaml`](./musher/component.yaml):

- **There are no literal environment variables.** A value that is the same for
  every deployment is still an input, one with a `default`, like
  `buildChannel`. A Blueprint that binds nothing to it gets the default, and
  nobody is asked. A value that must never change belongs in the image.
- **A sensitive input carries no `default`.** A default is published with the
  document, which is the one thing a secret must not be. The Blueprint feeds
  it from a generated parameter instead.
- **Every input has a `description`.** Publishing refuses one without: it is
  the help text the deploy form shows, so the form never has to restate it.

In [`musher/blueprint.yaml`](./musher/blueprint.yaml):

- **The deploy form is authored, not derived.** A parameter with `ui` is a
  field; a parameter without one is never offered. Parameters declare no
  schema of their own — the inputs they are bound to own it — so `greeting`'s
  form field is validated by the Component's `minLength: 1`.
- **`generator` is entropy, not a format.** `byteLength` is how many random
  bytes (16 to 64), and `encoding` is `HEX`, `BASE64` or `BASE64URL`.

## Hack on it

- **Offer the channel on the form.** Give `buildChannel` a
  `schema.enum: [stable, beta]`, then add a `buildChannel` parameter with a
  `ui.label` and bind it. The form renders a choice instead of a text field,
  derived from the schema.
- **Hide the greeting.** Delete the `greeting` parameter's `ui`. It still has a
  default, so it is an API-only parameter: deployments get the default unless a
  caller submits a value.
- **Rotate the token.** `POST /v1/deployments/{id}:rotateCredential` with
  `{"parameter": "adminToken"}` mints a new one and rolls the workload onto it.
- **Try to submit `adminToken`** in `parameters` and read the error. Being
  refused is the feature.

## Next

`notes-with-volume` — storage that outlives the container.
