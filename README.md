# Musher examples

Small, complete applications you can build, push, and deploy on
[Musher](https://musher.dev) — then take apart and rebuild as your own.

Each example is deliberately boring. The interesting part is not the app; it is
the two spec files next to it that describe how Musher should run it. Every
example adds exactly one new idea to the one before it, so you can stop at the
point where you have what you need.

> These are teaching examples, not production templates. They are pinned,
> health-checked, and run as non-root — but they have no auth, no rate limits,
> and no backups. Read them, then build yours.

## Start here

Work down the list. Each one adds a single idea to the one above it.

| Example | What it adds |
|---|---|
| [`hello-http`](./hello-http) | One HTTP service with a public URL and a readiness probe. The whole loop, end to end. |
| [`configurable-greeter`](./configurable-greeter) | Values the deployer chooses and secrets the platform generates. One image, many configurations. |
| [`notes-with-volume`](./notes-with-volume) | Storage that outlives the container. |
| [`counter-with-cache`](./counter-with-cache) | Two components wired together — a declared need met by a declared offer. |
| [`queue-worker`](./queue-worker) | A workload with no endpoint, and one output feeding two consumers. |

See [CONTRIBUTING.md](./CONTRIBUTING.md) if you want to add one.

## What you need

- A Musher account and an organization — sign up at
  [console.musher.dev](https://console.musher.dev).
- An API key from **Console → API Keys**, and your organization id.
- Docker (or any OCI builder) and somewhere to push images. The examples use
  [GitHub Container Registry](https://ghcr.io); Docker Hub or a private registry
  work identically.
- `curl`, `jq`, `yq`, and `envsubst` if you use the apply script.

```bash
export MUSHER_API_KEY="mush_..."
export MUSHER_ORG_ID="..."
```

## The shape of every example

```
<example>/
├── README.md              what it teaches, and how to run it
├── Dockerfile             how the image is built
├── src/                   the application itself
└── musher/
    ├── component.yaml     how Musher should run this workload
    └── blueprint.yaml     which components make up the app you deploy
```

A **Component** is the reusable, versioned definition of one workload — its
image, its ports, its health checks, its configuration. A **Blueprint** composes
one or more Components into the thing you actually deploy. A **Deployment** is a
running Blueprint. A single-service app is just a one-Component Blueprint, so
nothing you learn here gets thrown away when the app grows.

## Deploying one

Build and push your image, then apply the example:

```bash
cd hello-http
docker build -t ghcr.io/YOUR-USERNAME/hello-http:0.1.0 .
docker push ghcr.io/YOUR-USERNAME/hello-http:0.1.0

cd ..
./scripts/musher-apply.sh hello-http ghcr.io/YOUR-USERNAME/hello-http:0.1.0
```

`musher-apply.sh` creates and publishes the Components, composes and publishes
the Blueprint, and deploys it. It exists for one reason: a Blueprint references
Components by id, and you do not have those ids until the Components exist — so
something has to substitute them. Run it with `DRY_RUN=1` to see exactly what it
would send without changing anything.

Every step it takes has a plain `curl` equivalent in each example's README.
Nothing is hidden, and when the Musher CLI ships it will replace this script
rather than change the workflow.

## Pushing to a private registry

Public images need no credential. For a private one, register the credential
once per registry host in **Console → Configuration → Registry Credentials** —
Musher matches it to any image whose host matches, so nothing in
`component.yaml` changes.

## Documentation

- [Getting started](https://docs.musher.dev/getting-started)
- [Components](https://docs.musher.dev/concepts/components) ·
  [Blueprints](https://docs.musher.dev/concepts/blueprints) ·
  [Deployments](https://docs.musher.dev/concepts/deployments)
- [Component specification](https://docs.musher.dev/reference/component-spec) ·
  [Blueprint specification](https://docs.musher.dev/reference/blueprint-spec)

## Contributing

Issues and pull requests are welcome — see [CONTRIBUTING.md](./CONTRIBUTING.md).
If an example is wrong, unclear, or has stopped working, please
[open an issue](https://github.com/musher-dev/examples/issues/new/choose); a
broken example is worse than a missing one.

## License

[Apache-2.0](./LICENSE). Copy these into your own projects freely.
