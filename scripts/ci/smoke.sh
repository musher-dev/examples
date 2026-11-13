#!/bin/sh
#
# Start an example's image the way Musher would and answer its readiness probe.
#
# It stands in for the platform's wiring, from the example's own documents:
#
# - The probed node is the first whose Component is built from this example's
#   Dockerfile (image this-dockerfile.invalid/<example>) and declares an HTTP
#   readiness probe.
# - Every node whose Component wraps a public image starts as a sidecar, named
#   after its node, on a private network.
# - Each input of the probed Component with a `target.envVar` gets the value
#   Musher would resolve: a `node` binding takes the producer's output, with
#   `${{ self.endpoints.<e>.privateAddress }}` (or privateHostname,
#   privatePort) replaced by the sidecar's address; a `value` binding its
#   value; a `parameter` binding the parameter's default, or random bytes for
#   a generated one; an unbound input its default.
#
#   Usage: scripts/ci/smoke.sh <example> [image]     (image defaults to musher-examples/<example>:ci)

set -eu

[ $# -ge 1 ] || { echo "usage: $0 <example> [image]" >&2; exit 2; }
example="${1%/}"
image="${2:-musher-examples/$example:ci}"
spec="$example/musher"
bp="$spec/blueprint.yaml"
host_port="${SMOKE_PORT:-18080}"
SENTINEL_HOST="this-dockerfile.invalid"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

net="ci-$example-net"
containers=""
WORK=$(mktemp -d)
cleanup() {
  for c in $containers; do docker rm -f "$c" >/dev/null 2>&1 || true; done
  docker network rm "$net" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# component_of <node>: the Component file a node names.
component_of() {
  ref=$(yq -r ".spec.nodes.\"$1\".componentRef" "$bp")
  printf '%s/%s' "$spec" "${ref#./}"
}

# --- which node to probe -------------------------------------------------------

probe_node="" probe_file=""
for node in $(yq -r '.spec.nodes | keys | .[]' "$bp"); do
  f=$(component_of "$node")
  case "$(yq -r '.spec.workload.source.image // ""' "$f")" in
    "$SENTINEL_HOST"/*) ;;
    *) continue ;;
  esac
  if yq -e '.spec.workload.health.readiness.http.path' "$f" >/dev/null 2>&1; then
    probe_node="$node" probe_file="$f"
    break
  fi
done

docker network create "$net" >/dev/null

if [ -z "$probe_node" ]; then
  echo "no node built from this Dockerfile declares a readiness probe: start-only check"
  containers="ci-$example"
  docker run -d --network "$net" --name "ci-$example" "$image" >/dev/null
  sleep 3
  [ "$(docker inspect -f '{{.State.Running}}' "ci-$example")" = true ] || die "container exited"
  exit 0
fi

probe_endpoint=$(yq -r '.spec.workload.health.readiness.http.endpoint' "$probe_file")
probe_path=$(yq -r '.spec.workload.health.readiness.http.path' "$probe_file")
probe_port=$(yq -r ".spec.workload.endpoints.\"$probe_endpoint\".targetPort" "$probe_file")
echo "probing node $probe_node ($probe_file): GET $probe_path on port $probe_port"

# --- sidecars ------------------------------------------------------------------

for node in $(yq -r '.spec.nodes | keys | .[]' "$bp"); do
  f=$(component_of "$node")
  ref=$(yq -r '.spec.workload.source.image // ""' "$f")
  case "$ref" in "$SENTINEL_HOST"/* | '') continue ;; esac
  containers="$containers $node"
  docker run -d --network "$net" --name "$node" "$ref" >/dev/null
  echo "sidecar $node <- $ref"
done

# --- environment ---------------------------------------------------------------

# resolve_output <node> <output>: the value Musher would resolve for it.
resolve_output() {
  pf=$(component_of "$1")
  out=".spec.contract.outputs.\"$2\".from"
  if yq -e "$out.template" "$pf" >/dev/null 2>&1; then
    value=$(yq -r "$out.template" "$pf")
  elif yq -e "$out.endpoint" "$pf" >/dev/null 2>&1; then
    value="\${{ self.endpoints.$(yq -r "$out.endpoint" "$pf").$(yq -r "$out.property" "$pf") }}"
  elif yq -e "$out | has(\"value\")" "$pf" >/dev/null 2>&1; then
    value=$(yq -r "$out.value" "$pf")
  else
    die "output $2 of node $1: only template, endpoint and value origins are simulated"
  fi
  for e in $(yq -r '.spec.workload.endpoints // {} | keys | .[]' "$pf"); do
    p=$(yq -r ".spec.workload.endpoints.\"$e\".targetPort" "$pf")
    value=$(printf '%s' "$value" | sed \
      -e "s/\${{ *self\.endpoints\.$e\.privateAddress *}}/$1:$p/g" \
      -e "s/\${{ *self\.endpoints\.$e\.privateHostname *}}/$1/g" \
      -e "s/\${{ *self\.endpoints\.$e\.privatePort *}}/$p/g")
  done
  # shellcheck disable=SC2016 # a literal ${{, the start of an unresolved placeholder
  case "$value" in *'${{'*) die "output $2 of node $1 reads something only the platform has: $value" ;; esac
  printf '%s' "$value"
}

: >"$WORK/env"
binding() { printf '.spec.nodes."%s".bindings."%s"' "$probe_node" "$1"; }
for input in $(yq -r '.spec.contract.inputs // {} | keys | .[]' "$probe_file"); do
  in=".spec.contract.inputs.\"$input\""
  var=$(yq -r "$in.target.envVar // \"\"" "$probe_file")
  [ -n "$var" ] || continue
  b=$(binding "$input")
  if yq -e "$b.node" "$bp" >/dev/null 2>&1; then
    value=$(resolve_output "$(yq -r "$b.node" "$bp")" "$(yq -r "$b.output" "$bp")")
  elif yq -e "$b | has(\"value\")" "$bp" >/dev/null 2>&1; then
    value=$(yq -r "$b.value" "$bp")
  elif yq -e "$b.parameter" "$bp" >/dev/null 2>&1; then
    param=".spec.parameters.\"$(yq -r "$b.parameter" "$bp")\""
    if yq -e "$param.generator" "$bp" >/dev/null 2>&1; then
      value=$(head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n')
    elif yq -e "$param | has(\"default\")" "$bp" >/dev/null 2>&1; then
      value=$(yq -r "$param.default" "$bp")
    else
      echo "input $input: parameter has no default; leaving $var unset"
      continue
    fi
  elif yq -e "$in | has(\"default\")" "$probe_file" >/dev/null 2>&1; then
    value=$(yq -r "$in.default" "$probe_file")
  else
    echo "input $input: unbound, no default; leaving $var unset"
    continue
  fi
  printf '%s=%s\n' "$var" "$value" >>"$WORK/env"
  case "$(yq -r "$in.sensitive // false" "$probe_file")" in
    true) echo "env $var=<sensitive>" ;;
    *) echo "env $var=$value" ;;
  esac
done

# --- probe ---------------------------------------------------------------------

containers="$containers ci-$example"
docker run -d --network "$net" --name "ci-$example" --env-file "$WORK/env" \
  -p "$host_port:$probe_port" "$image" >/dev/null

i=0
while [ $i -lt 30 ]; do
  curl -fsS "http://localhost:$host_port$probe_path" >/dev/null 2>&1 && break
  i=$((i + 1))
  sleep 1
done
curl -fsS "http://localhost:$host_port$probe_path" || {
  echo
  docker logs "ci-$example" >&2 || true
  die "readiness probe never answered"
}
echo
