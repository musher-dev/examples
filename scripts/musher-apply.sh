#!/usr/bin/env bash
#
# Apply one example to your Musher organization: create and publish its
# Components, compose and publish its Blueprint, then deploy.
#
# This exists because a Blueprint references Components by id, and you do not
# have those ids until the Components exist. The script does the substitution
# so you do not have to paste UUIDs by hand.
#
# It is a stopgap. When the Musher CLI ships it will do this in one command,
# and every step below has a plain `curl` equivalent documented in the
# example's README — nothing here is hidden from you.
#
#   Usage: scripts/musher-apply.sh <example-dir> <image-ref> [deployment-name]
#
#   Required environment:
#     MUSHER_API_KEY   an API key from https://console.musher.dev/console/api-keys
#     MUSHER_ORG_ID    your organization id
#
#   Optional:
#     MUSHER_API_URL   defaults to https://api.musher.dev
#     DRY_RUN=1        print what would be sent, change nothing

set -euo pipefail

API_URL="${MUSHER_API_URL:-https://api.musher.dev}"
DRY_RUN="${DRY_RUN:-}"

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
ok() { printf '\033[32m  ✓\033[0m %s\n' "$*"; }

# --- preflight ---------------------------------------------------------------

for tool in curl jq yq envsubst; do
  command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done

[[ $# -ge 2 ]] || die "usage: $0 <example-dir> <image-ref> [deployment-name]"

EXAMPLE_DIR="${1%/}"
export IMAGE_REF="$2"
DEPLOYMENT_NAME="${3:-$(basename "$EXAMPLE_DIR")}"

[[ -d "$EXAMPLE_DIR/musher" ]] || die "no musher/ directory in $EXAMPLE_DIR"
[[ -n "${MUSHER_API_KEY:-}" ]] || die "MUSHER_API_KEY is not set"
[[ -n "${MUSHER_ORG_ID:-}" ]] || die "MUSHER_ORG_ID is not set"

# A floating tag is rejected when Musher publishes the Component, and the error
# arrives three steps later than the mistake. Catch it here instead.
case "$IMAGE_REF" in
  *:latest|*:main|*:master|*:stable|*:edge|*:nightly|*:dev|*:rolling)
    die "image ref '$IMAGE_REF' uses a floating tag; publish requires a pinned tag or digest" ;;
  # Anything else with a ':' carries a tag or a @sha256 digest — both are fine.
  *:*) ;;
  *) die "image ref '$IMAGE_REF' has no tag; use e.g. ${IMAGE_REF}:0.1.0" ;;
esac

# --- http helper -------------------------------------------------------------

# api <METHOD> <PATH> [BODY]  → response body on stdout; non-2xx is fatal.
api() {
  local method="$1" path="$2" body="${3:-}"
  local response status
  local -a args=(
    --silent --show-error --write-out '\n%{http_code}'
    --request "$method" "$API_URL$path"
    --header "Authorization: Bearer $MUSHER_API_KEY"
    --header "Content-Type: application/json"
  )
  [[ -n "$body" ]] && args+=(--data "$body")

  response="$(curl "${args[@]}")" || die "request failed: $method $path"
  status="$(tail -n1 <<<"$response")"
  response="$(sed '$d' <<<"$response")"

  if [[ ! "$status" =~ ^2 ]]; then
    printf '\033[31merror:\033[0m %s %s → HTTP %s\n' "$method" "$path" "$status" >&2
    # The API speaks RFC 9457, so `detail` is where the useful sentence lives.
    jq -r '.detail // .title // .' <<<"$response" >&2 2>/dev/null || printf '%s\n' "$response" >&2
    exit 1
  fi
  printf '%s' "$response"
}

# spec_json <file>  → the file with ${...} placeholders substituted, as JSON,
# with the specVersion/kind envelope stripped (today's create endpoints take
# the {metadata, spec} body; the envelope is what the declarative /spec
# endpoints consume).
spec_json() {
  envsubst <"$1" | yq -o=json '{"metadata": .metadata, "spec": .spec}'
}

# --- components --------------------------------------------------------------

declare -a COMPONENT_IDS=()

for component_file in "$EXAMPLE_DIR"/musher/component*.yaml; do
  [[ -e "$component_file" ]] || die "no component*.yaml found in $EXAMPLE_DIR/musher"

  slug="$(yq -r '.metadata.slug' "$component_file")"
  info "Component: $slug"

  payload="$(spec_json "$component_file")"
  var_prefix="$(tr '[:lower:]-' '[:upper:]_' <<<"$slug")"

  if [[ -n "$DRY_RUN" ]]; then
    jq . <<<"$payload"
    # Give the Blueprint something recognisable to render, so a dry run shows
    # its real shape instead of nulls.
    export "${var_prefix}_COMPONENT_ID=<${slug}-component-id>"
    export "${var_prefix}_COMPONENT_VERSION=<version>"
    continue
  fi

  created="$(api POST "/v1/organizations/$MUSHER_ORG_ID/components" "$payload")"
  component_id="$(jq -r '.metadata.id' <<<"$created")"
  component_version="$(jq -r '.metadata.version' <<<"$created")"
  ok "drafted $slug v$component_version ($component_id)"

  api POST "/v1/components/$component_id:publish" >/dev/null
  ok "published"

  # Export as ${SLUG_COMPONENT_ID} / ${SLUG_COMPONENT_VERSION} for blueprint.yaml.
  export "${var_prefix}_COMPONENT_ID=$component_id"
  export "${var_prefix}_COMPONENT_VERSION=$component_version"
  COMPONENT_IDS+=("$component_id")
done

# --- blueprint ---------------------------------------------------------------

blueprint_file="$EXAMPLE_DIR/musher/blueprint.yaml"
[[ -f "$blueprint_file" ]] || die "no blueprint.yaml in $EXAMPLE_DIR/musher"

info "Blueprint: $(yq -r '.metadata.slug' "$blueprint_file")"
blueprint_payload="$(spec_json "$blueprint_file")"

if [[ -n "$DRY_RUN" ]]; then
  jq . <<<"$blueprint_payload"
  info "dry run — nothing was created"
  exit 0
fi

blueprint="$(api POST "/v1/organizations/$MUSHER_ORG_ID/blueprints" "$blueprint_payload")"
blueprint_id="$(jq -r '.metadata.id' <<<"$blueprint")"
ok "composed ($blueprint_id)"

api POST "/v1/blueprints/$blueprint_id:publish" >/dev/null
ok "published"

# --- deploy ------------------------------------------------------------------

info "Deploying as '$DEPLOYMENT_NAME'"

deploy_payload="$(jq -n \
  --arg id "$blueprint_id" \
  --arg name "$DEPLOYMENT_NAME" \
  '{blueprintId: $id, userAssignedName: $name, replicas: 1}')"

deployment="$(api POST "/v1/organizations/$MUSHER_ORG_ID/deployments:deployBlueprint" "$deploy_payload")"
deployment_id="$(jq -r '.metadata.id // .id' <<<"$deployment")"
ok "deployment $deployment_id"

cat <<EOF

Deployed. Watch it come up:

  curl -H "Authorization: Bearer \$MUSHER_API_KEY" \\
    $API_URL/v1/deployments/$deployment_id | jq '.status'

Then fetch its URL:

  curl -H "Authorization: Bearer \$MUSHER_API_KEY" \\
    $API_URL/v1/organizations/\$MUSHER_ORG_ID/deployments/$deployment_id/endpoints | jq

Or open it in the console:

  https://console.musher.dev/deployments/$deployment_id
EOF
