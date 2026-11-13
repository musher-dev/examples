#!/bin/sh
#
# Validate every example's Musher documents.
#
#   1. Each document against the pinned JSON Schema of its family
#      (pins/schemas/), with check-jsonschema: component*.yaml as a component,
#      blueprint.yaml as a blueprint.
#   2. What the apply script relies on and a schema cannot see: every node of a
#      Blueprint names a component*.yaml file beside it, every such file is
#      named by a node, and every image is either the Dockerfile placeholder
#      or a pinned tag.
#
# The schemas are the structural phase only. The semantic rules (an unbound
# required input, a PUBLIC endpoint without a readiness probe) run on the
# server when a Component or Blueprint is published; contract-test.py and a
# live apply are what reach those.
#
#   Usage: scripts/check/specs.sh

set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
cd "$ROOT"

SENTINEL_HOST="this-dockerfile.invalid"
status=0
fail() {
  if [ "${GITHUB_ACTIONS:-}" = true ]; then printf '::error file=%s::%s\n' "$1" "$2"; fi
  printf 'FAIL %s: %s\n' "$1" "$2"
  status=1
}

command -v check-jsonschema >/dev/null 2>&1 \
  || { echo "check-jsonschema is not installed (pipx install check-jsonschema)" >&2; exit 1; }

# --- 1. schemas ----------------------------------------------------------------

printf '== component documents against %s\n' "$(jq -r '.specifications.component.url' pins/pins.json)"
# shellcheck disable=SC2046 # one argument per file, and no file name has a space
check-jsonschema --schemafile pins/schemas/component.schema.json $(ls ./*/musher/component*.yaml) || status=1

printf '== blueprint documents against %s\n' "$(jq -r '.specifications.blueprint.url' pins/pins.json)"
# shellcheck disable=SC2046
check-jsonschema --schemafile pins/schemas/blueprint.schema.json $(ls ./*/musher/blueprint.yaml) || status=1

for f in ./*/musher/*.yaml; do
  case "$(basename "$f")" in
    component*.yaml | blueprint.yaml) ;;
    *) fail "$f" "not component*.yaml or blueprint.yaml; the apply script would ignore it" ;;
  esac
done

# --- 2. what the apply script relies on ---------------------------------------

printf '== examples\n'
for dir in ./*/; do
  example=$(basename "$dir")
  [ -f "$dir/Dockerfile" ] || continue
  spec="$dir/musher"
  bp="$spec/blueprint.yaml"
  [ -f "$bp" ] || { fail "$dir" "has a Dockerfile but no musher/blueprint.yaml"; continue; }

  # Every node names a component file beside the Blueprint.
  for ref in $(yq -r '.spec.nodes // {} | to_entries[] | .value.componentRef' "$bp"); do
    case "$ref" in
      ./component*.yaml) [ -f "$spec/${ref#./}" ] || fail "$bp" "names $ref, which does not exist" ;;
      *) fail "$bp" "names '$ref'; nodes must name a ./component*.yaml file beside blueprint.yaml" ;;
    esac
  done
  # And every component file is named by a node, or it would never be deployed.
  for f in "$spec"/component*.yaml; do
    [ -f "$f" ] || continue
    yq -e ".spec.nodes[] | select(.componentRef == \"./$(basename "$f")\")" "$bp" >/dev/null 2>&1 \
      || fail "$f" "no node in blueprint.yaml names it"
  done

  # Images: the Dockerfile placeholder, or a pinned public image.
  for f in "$spec"/component*.yaml; do
    [ -f "$f" ] || continue
    image=$(yq -r '.spec.workload.source.image // ""' "$f")
    case "$image" in
      '') ;;
      "$SENTINEL_HOST/$example") ;;
      "$SENTINEL_HOST"/*) fail "$f" "placeholder image should be $SENTINEL_HOST/$example" ;;
      *@sha256:*) ;;
      *:latest | *:main | *:master | *:stable | *:edge | *:nightly | *:dev | *:rolling | *:alpine | *:slim)
        fail "$f" "image '$image' uses a floating tag; pin a version" ;;
      *) case "${image##*/}" in
           *:*) ;;
           *) fail "$f" "image '$image' has no tag; pin a version" ;;
         esac ;;
    esac
  done
  printf 'ok   %s\n' "$example"
done

exit $status
