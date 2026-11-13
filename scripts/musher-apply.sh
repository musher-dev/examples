#!/bin/sh
#
# Apply one example to your Musher organization: publish its Components,
# publish its Blueprint, then deploy it.
#
# This exists because a Blueprint written through the API names each Component
# by id and revision, and you do not have those until the Components are
# published. blueprint.yaml names them by file instead (`./component.yaml`), and
# this script swaps each file for the id and revision it just published.
#
# It is a stopgap. When the Musher CLI ships it will do this in one command,
# and every step below has a plain `curl` equivalent in hello-http's README —
# nothing here is hidden from you.
#
#   Usage: scripts/musher-apply.sh <example-dir> <image-ref> [deployment-name]
#
#   Required environment:
#     MUSHER_API_KEY   an API key from https://console.musher.dev (API Keys)
#     MUSHER_ORG_ID    your organization id
#
#   Optional:
#     MUSHER_API_URL   defaults to https://api.musher.dev
#     DRY_RUN=1        print what would be sent, change nothing, call nothing
#
# Re-running it is safe. A Component or Blueprint whose document has not
# changed is reused; one that has changed gets the next revision; and a
# deployment that already exists under this name is moved to the new Blueprint
# revision instead of being created twice.
#
# Every request goes through `api` or `request` below with a literal path, so
# CI can check each one against the pinned OpenAPI description
# (scripts/check/api-routes.py). Keep it that way.

set -eu

API_URL="${MUSHER_API_URL:-https://api.musher.dev}"
API_URL="${API_URL%/}"
DRY_RUN="${DRY_RUN:-}"

# The image reference a document uses for "the image built from this example's
# Dockerfile". `.invalid` never resolves, so a document applied without this
# script's substitution fails instead of pulling an image nobody built.
SENTINEL_HOST="this-dockerfile.invalid"

# --- output ------------------------------------------------------------------

if [ -t 2 ]; then
  C_RED=$(printf '\033[31m') C_CYAN=$(printf '\033[36m') C_GREEN=$(printf '\033[32m') C_OFF=$(printf '\033[0m')
else
  C_RED='' C_CYAN='' C_GREEN='' C_OFF=''
fi

die() { printf '%serror:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }
info() { printf '%s==>%s %s\n' "$C_CYAN" "$C_OFF" "$*" >&2; }
ok() { printf '%s  ok%s %s\n' "$C_GREEN" "$C_OFF" "$*" >&2; }

usage() {
  printf 'usage: %s <example-dir> <image-ref> [deployment-name]\n' "$0" >&2
  exit 2
}

# --- preflight ---------------------------------------------------------------

[ $# -ge 2 ] && [ $# -le 3 ] || usage

for tool in curl jq yq; do
  command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done
# There are two programs called yq. This script needs mikefarah's (Go), which
# reads YAML with `-o=json`; the Python one takes different flags.
yq --version 2>&1 | grep -q mikefarah \
  || die "yq is not mikefarah/yq (https://github.com/mikefarah/yq); install that one"

EXAMPLE_DIR="${1%/}"
IMAGE_REF="$2"
SPEC_DIR="$EXAMPLE_DIR/musher"
BLUEPRINT_FILE="$SPEC_DIR/blueprint.yaml"

[ -d "$SPEC_DIR" ] || die "no musher/ directory in '$EXAMPLE_DIR'"
[ -f "$BLUEPRINT_FILE" ] || die "no blueprint.yaml in '$SPEC_DIR'"

BLUEPRINT_SLUG=$(yq -r '.metadata.slug // ""' "$BLUEPRINT_FILE") \
  || die "$BLUEPRINT_FILE is not valid YAML"
[ -n "$BLUEPRINT_SLUG" ] || die "$BLUEPRINT_FILE has no metadata.slug"

DEPLOYMENT_NAME="${3:-$BLUEPRINT_SLUG}"
printf '%s' "$DEPLOYMENT_NAME" | grep -Eq '^[a-z][a-z0-9-]{0,61}[a-z0-9]$' \
  || die "deployment name '$DEPLOYMENT_NAME' must be a DNS label: lowercase letters, digits and '-', starting with a letter"

# Musher accepts any tag and pins the digest it resolves at deploy time. These
# examples still insist on a version: with a moving tag, the same Component
# revision can run different code tomorrow, and nobody can say which.
case "${IMAGE_REF##*/}" in
  *@sha256:*) ;;
  *:latest | *:main | *:master | *:stable | *:edge | *:nightly | *:dev | *:rolling)
    die "image ref '$IMAGE_REF' uses a floating tag; tag it with a version (e.g. :0.1.0) or pin a digest" ;;
  *:*) ;;
  *) die "image ref '$IMAGE_REF' has no tag; use e.g. ${IMAGE_REF}:0.1.0" ;;
esac
case "$IMAGE_REF" in
  "$SENTINEL_HOST"/*) die "pass the image you pushed, not the placeholder '$IMAGE_REF'" ;;
esac

if [ -z "$DRY_RUN" ]; then
  [ -n "${MUSHER_API_KEY:-}" ] || die "MUSHER_API_KEY is not set (create one in the console under API Keys)"
  [ -n "${MUSHER_ORG_ID:-}" ] || die "MUSHER_ORG_ID is not set"
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM

# --- http --------------------------------------------------------------------

# request <METHOD> <PATH> [BODY-FILE]
#   Sends one request. Prints the HTTP status; the body is left in $WORK/body.
request() {
  if [ -n "${3:-}" ]; then
    curl --silent --show-error --output "$WORK/body" --write-out '%{http_code}' \
      --request "$1" "$API_URL$2" \
      --header "Authorization: Bearer $MUSHER_API_KEY" \
      --header "Accept: application/json" \
      --header "Content-Type: application/json" \
      --data-binary "@$3" \
      || die "could not reach $API_URL ($1 $2)"
  else
    curl --silent --show-error --output "$WORK/body" --write-out '%{http_code}' \
      --request "$1" "$API_URL$2" \
      --header "Authorization: Bearer $MUSHER_API_KEY" \
      --header "Accept: application/json" \
      || die "could not reach $API_URL ($1 $2)"
  fi
}

# api <METHOD> <PATH> [BODY-FILE]
#   Like request, but prints the body, and a non-2xx status is fatal.
api() {
  api_status=$(request "$@") || exit 1
  case "$api_status" in
    2??) cat "$WORK/body" ;;
    *) fail_response "$1 $2" "$api_status" ;;
  esac
}

# The API answers errors with RFC 9457 problem documents. A refused document
# (spec-document-invalid) lists every diagnostic with the JSON pointer it is
# at, which is the line worth reading; print those rather than the raw body.
fail_response() {
  printf '%serror:%s %s -> HTTP %s\n' "$C_RED" "$C_OFF" "$1" "$2" >&2
  jq -r '
    [ (.title // empty), (.detail // empty) ] | join(": ") | select(. != "")
  ' "$WORK/body" >&2 2>/dev/null || cat "$WORK/body" >&2
  jq -r '
    ((.errors // [])[] | "  - \(.pointer // .field // "")  \(.code // .type // "")  \(.message // "")"),
    ((.deferred // [])[] | "  - deferred: \(.rule // "")  \(.path // "")  \(.missing // "")"),
    (.traceId // empty | "  trace id: \(.)")
  ' "$WORK/body" >&2 2>/dev/null || true
  case "$2" in
    401) printf '  hint: MUSHER_API_KEY was refused; check it has not expired or been revoked\n' >&2 ;;
    403) printf '  hint: the API key lacks a permission this step needs\n' >&2 ;;
  esac
  exit 1
}

# --- documents ---------------------------------------------------------------

# to_json <yaml-file> <out-file>: the document as JSON, image placeholder
# replaced with $IMAGE_REF.
to_json() {
  yq -o=json '.' "$1" >"$WORK/raw.json" || die "$1 is not valid YAML"
  jq --arg host "$SENTINEL_HOST/" --arg image "$IMAGE_REF" '
    if ((.spec.workload.source.image? // "") | startswith($host))
    then .spec.workload.source.image = $image
    else . end
  ' "$WORK/raw.json" >"$2"
}

# with_revision <doc-file> <revision> <out-file>
with_revision() {
  jq --argjson rev "$2" '.metadata.revision = $rev' "$1" >"$3"
}

# same_document <doc-file> <stored-file>: true when they differ only in revision.
same_document() {
  [ "$(jq -S -c 'del(.metadata.revision)' "$1")" = "$(jq -S -c 'del(.metadata.revision)' "$2")" ]
}

# next_revision <versions-page-files...>: one more than the highest revision in
# any of them. The API refuses a revision that does not exceed every one the
# lineage has released.
next_revision() {
  jq -s '[.[].data[].revision] | (max // 0) + 1' "$@"
}

# --- components --------------------------------------------------------------

# apply_component <slug> <doc-file>: sets PUBLISHED_ID and PUBLISHED_REV.
# (Globals, not output: a function run inside $(...) loses `set -e` in bash.)
apply_component() {
  c_slug="$1" c_doc="$2"

  api GET "/v1/organizations/$MUSHER_ORG_ID/components?slug=$c_slug" >"$WORK/found.json"
  c_id=$(jq -r '.data[0].id // ""' "$WORK/found.json")

  if [ -z "$c_id" ]; then
    with_revision "$c_doc" 1 "$WORK/doc.json"
    jq -n --arg slug "$c_slug" --slurpfile doc "$WORK/doc.json" \
      '{slug: $slug, document: $doc[0]}' >"$WORK/req.json"
    api POST "/v1/organizations/$MUSHER_ORG_ID/components" "$WORK/req.json" >"$WORK/version.json"
    c_rev=$(jq -r '.revision' "$WORK/version.json")
    c_id=$(jq -r '.componentId' "$WORK/version.json")
    ok "created $c_slug, draft revision $c_rev"
  else
    c_published=$(jq -r '.data[0].latestPublishedVersion.revision // ""' "$WORK/found.json")
    c_draft=$(jq -r '.data[0].draftVersion.revision // ""' "$WORK/found.json")

    if [ -n "$c_published" ]; then
      api GET "/v1/components/$c_id/versions/$c_published/document" >"$WORK/stored.json"
      if same_document "$c_doc" "$WORK/stored.json"; then
        ok "$c_slug unchanged, reusing revision $c_published"
        PUBLISHED_ID="$c_id" PUBLISHED_REV="$c_published"
        return 0
      fi
    fi

    if [ -n "$c_draft" ]; then
      # Only one draft may be open; a failed earlier run can leave one. Replace it.
      c_rev="$c_draft"
      with_revision "$c_doc" "$c_rev" "$WORK/doc.json"
      jq -n --slurpfile doc "$WORK/doc.json" '{document: $doc[0]}' >"$WORK/req.json"
      api PUT "/v1/components/$c_id/versions/$c_rev" "$WORK/req.json" >/dev/null
      ok "replaced $c_slug's open draft, revision $c_rev"
    else
      c_page=0 c_cursor=''
      while :; do
        c_page=$((c_page + 1))
        api GET "/v1/components/$c_id/versions?limit=100&cursor=$c_cursor" >"$WORK/versions.$c_page.json"
        [ "$(jq -r '.meta.hasMore // false' "$WORK/versions.$c_page.json")" = true ] || break
        c_cursor=$(jq -r '.meta.nextCursor' "$WORK/versions.$c_page.json")
      done
      c_rev=$(next_revision "$WORK"/versions.*.json)
      rm -f "$WORK"/versions.*.json
      with_revision "$c_doc" "$c_rev" "$WORK/doc.json"
      jq -n --slurpfile doc "$WORK/doc.json" '{document: $doc[0]}' >"$WORK/req.json"
      api POST "/v1/components/$c_id/versions" "$WORK/req.json" >/dev/null
      ok "drafted $c_slug revision $c_rev"
    fi
  fi

  # A draft can be edited; a published revision cannot, which is what makes it
  # safe for a Blueprint to pin. Publishing is where every rule is enforced.
  api POST "/v1/components/$c_id/versions/$c_rev:publish" >/dev/null
  ok "published $c_slug revision $c_rev"
  PUBLISHED_ID="$c_id" PUBLISHED_REV="$c_rev"
}

# --- blueprint ---------------------------------------------------------------

# apply_blueprint <slug> <doc-file>: sets PUBLISHED_ID and PUBLISHED_REV.
apply_blueprint() {
  b_slug="$1" b_doc="$2"

  api GET "/v1/organizations/$MUSHER_ORG_ID/blueprints?slug=$b_slug" >"$WORK/found.json"
  b_id=$(jq -r '.data[0].id // ""' "$WORK/found.json")

  if [ -z "$b_id" ]; then
    with_revision "$b_doc" 1 "$WORK/doc.json"
    jq -n --arg slug "$b_slug" --slurpfile doc "$WORK/doc.json" \
      '{slug: $slug, document: $doc[0]}' >"$WORK/req.json"
    api POST "/v1/organizations/$MUSHER_ORG_ID/blueprints" "$WORK/req.json" >"$WORK/version.json"
    b_rev=$(jq -r '.revision' "$WORK/version.json")
    b_id=$(jq -r '.blueprintId' "$WORK/version.json")
    ok "created $b_slug, draft revision $b_rev"
  else
    b_published=$(jq -r '.data[0].latestPublishedVersion.revision // ""' "$WORK/found.json")
    b_draft=$(jq -r '.data[0].draftVersion.revision // ""' "$WORK/found.json")

    if [ -n "$b_published" ]; then
      api GET "/v1/blueprints/$b_id/versions/$b_published/document" >"$WORK/stored.json"
      if same_document "$b_doc" "$WORK/stored.json"; then
        ok "$b_slug unchanged, reusing revision $b_published"
        PUBLISHED_ID="$b_id" PUBLISHED_REV="$b_published"
        return 0
      fi
    fi

    if [ -n "$b_draft" ]; then
      b_rev="$b_draft"
      with_revision "$b_doc" "$b_rev" "$WORK/doc.json"
      jq -n --slurpfile doc "$WORK/doc.json" '{document: $doc[0]}' >"$WORK/req.json"
      api PUT "/v1/blueprints/$b_id/versions/$b_rev" "$WORK/req.json" >/dev/null
      ok "replaced $b_slug's open draft, revision $b_rev"
    else
      b_page=0 b_cursor=''
      while :; do
        b_page=$((b_page + 1))
        api GET "/v1/blueprints/$b_id/versions?limit=100&cursor=$b_cursor" >"$WORK/versions.$b_page.json"
        [ "$(jq -r '.meta.hasMore // false' "$WORK/versions.$b_page.json")" = true ] || break
        b_cursor=$(jq -r '.meta.nextCursor' "$WORK/versions.$b_page.json")
      done
      b_rev=$(next_revision "$WORK"/versions.*.json)
      rm -f "$WORK"/versions.*.json
      with_revision "$b_doc" "$b_rev" "$WORK/doc.json"
      jq -n --slurpfile doc "$WORK/doc.json" '{document: $doc[0]}' >"$WORK/req.json"
      api POST "/v1/blueprints/$b_id/versions" "$WORK/req.json" >/dev/null
      ok "drafted $b_slug revision $b_rev"
    fi
  fi

  api POST "/v1/blueprints/$b_id/versions/$b_rev:publish" >/dev/null
  ok "published $b_slug revision $b_rev"
  PUBLISHED_ID="$b_id" PUBLISHED_REV="$b_rev"
}

# --- 1. components -----------------------------------------------------------

# refs.json maps each component file, as blueprint.yaml names it, to what was
# published: {"./component.yaml": {"id": "...", "revision": 3}}.
printf '{}' >"$WORK/refs.json"
found=''

for component_file in "$SPEC_DIR"/component*.yaml; do
  [ -f "$component_file" ] || continue
  found=1
  file=$(basename "$component_file")
  # A Component document has no slug of its own. Name it in your library after
  # the Blueprint and the file: component.yaml is "<blueprint>", and
  # component-web.yaml is "<blueprint>-web".
  suffix=${file%.yaml}
  suffix=${suffix#component}
  slug="$BLUEPRINT_SLUG$suffix"
  info "Component $slug ($file)"

  to_json "$component_file" "$WORK/component.json"

  if [ -n "$DRY_RUN" ]; then
    with_revision "$WORK/component.json" 1 "$WORK/doc.json"
    jq -n --arg slug "$slug" --slurpfile doc "$WORK/doc.json" '{slug: $slug, document: $doc[0]}'
    id="<id of $slug>" rev=1
  else
    apply_component "$slug" "$WORK/component.json"
    id="$PUBLISHED_ID" rev="$PUBLISHED_REV"
  fi

  jq --arg ref "./$file" --arg id "$id" --argjson rev "$rev" \
    '.[$ref] = {id: $id, revision: $rev}' "$WORK/refs.json" >"$WORK/refs.next"
  mv "$WORK/refs.next" "$WORK/refs.json"
done

[ -n "$found" ] || die "no component*.yaml in $SPEC_DIR"

# --- 2. blueprint ------------------------------------------------------------

info "Blueprint $BLUEPRINT_SLUG"

to_json "$BLUEPRINT_FILE" "$WORK/blueprint.raw.json"

# Every node must name one of the files just published, or the Blueprint would
# deploy something this example did not define.
unknown=$(jq -r --slurpfile refs "$WORK/refs.json" '
  .spec.nodes // {} | to_entries[]
  | select(($refs[0][.value.componentRef] // null) == null)
  | "\(.key) -> \(.value.componentRef)"
' "$WORK/blueprint.raw.json")
[ -z "$unknown" ] || die "blueprint.yaml names components that are not musher/component*.yaml files: $unknown"

jq --slurpfile refs "$WORK/refs.json" '
  .spec.nodes |= map_values(
    $refs[0][.componentRef] as $ref
    | .componentRef = $ref.id
    | .revision = $ref.revision
  )
' "$WORK/blueprint.raw.json" >"$WORK/blueprint.json"

if [ -n "$DRY_RUN" ]; then
  with_revision "$WORK/blueprint.json" 1 "$WORK/doc.json"
  jq -n --arg slug "$BLUEPRINT_SLUG" --slurpfile doc "$WORK/doc.json" '{slug: $slug, document: $doc[0]}'
  info "Deploy as '$DEPLOYMENT_NAME'"
  jq -n --arg name "$DEPLOYMENT_NAME" \
    '{blueprintId: "<id of the blueprint>", revision: 1, name: $name, replicas: 1}'
  info "dry run: nothing was sent"
  exit 0
fi

apply_blueprint "$BLUEPRINT_SLUG" "$WORK/blueprint.json"
blueprint_id="$PUBLISHED_ID" blueprint_rev="$PUBLISHED_REV"

# --- 3. deploy ---------------------------------------------------------------

info "Deployment '$DEPLOYMENT_NAME'"

status=$(request GET "/v1/organizations/$MUSHER_ORG_ID/deployments:byName?name=$DEPLOYMENT_NAME")
case "$status" in
  404)
    jq -n --arg id "$blueprint_id" --argjson rev "$blueprint_rev" --arg name "$DEPLOYMENT_NAME" \
      '{blueprintId: $id, revision: $rev, name: $name, replicas: 1}' >"$WORK/req.json"
    api POST "/v1/organizations/$MUSHER_ORG_ID/deployments:deployBlueprint" "$WORK/req.json" >"$WORK/deployment.json"
    deployment_id=$(jq -r '.metadata.id' "$WORK/deployment.json")
    ok "deployed revision $blueprint_rev as $deployment_id"
    ;;
  200)
    deployment_id=$(jq -r '.metadata.id' "$WORK/body")
    current_blueprint=$(jq -r '.spec.blueprintId // ""' "$WORK/body")
    current_rev=$(jq -r '.spec.blueprintVersion // ""' "$WORK/body")
    [ "$current_blueprint" = "$blueprint_id" ] \
      || die "a deployment named '$DEPLOYMENT_NAME' already exists and runs another Blueprint; pass a different name as the third argument"
    if [ "$current_rev" = "$blueprint_rev" ]; then
      ok "$deployment_id already runs revision $blueprint_rev; nothing to change"
    else
      jq -n --argjson rev "$blueprint_rev" '{revision: $rev}' >"$WORK/req.json"
      api POST "/v1/deployments/$deployment_id:update" "$WORK/req.json" >/dev/null
      ok "moved $deployment_id from revision $current_rev to $blueprint_rev"
    fi
    ;;
  *) fail_response "GET deployments:byName" "$status" ;;
esac

cat <<EOF

Watch it come up (ACTIVE means running):

  curl -fsS -H "Authorization: Bearer \$MUSHER_API_KEY" \\
    $API_URL/v1/deployments/$deployment_id | jq '.status.phase'

Then fetch its public URL:

  curl -fsS -H "Authorization: Bearer \$MUSHER_API_KEY" \\
    $API_URL/v1/organizations/\$MUSHER_ORG_ID/deployments/$deployment_id/endpoints \\
    | jq -r '.data[] | select(.visibility == "PUBLIC") | "\(.publicScheme)://\(.publicHostname)"'

Or open it in the console: https://console.musher.dev/deployments/$deployment_id
EOF
