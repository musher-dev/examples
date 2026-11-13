#!/bin/sh
#
# Has anything upstream moved past the pins? Run weekly by
# .github/workflows/upstream.yml; also fine to run by hand.
#
#   1. A newer release of the component or blueprint specification than the
#      one pinned. Within a major version that is additive, so nothing here
#      is broken yet, but the pin is falling behind: bump it.
#   2. The live API (https://api.musher.dev/openapi.json) no longer has a
#      route the script or a README calls, or no longer accepts what the
#      script sends. That is a broken example today.
#
# Exit status 1 when either is true. It never changes a file; the fix is
# scripts/pins/update.sh and whatever the checks then report.
#
#   Usage: scripts/check/upstream.sh        (needs curl, jq, python3 with jsonschema)

set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
SPECS_HOST="https://specifications.musher.dev"
LIVE_OPENAPI="${MUSHER_OPENAPI_URL:-https://api.musher.dev/openapi.json}"
status=0

note() {
  if [ "${GITHUB_ACTIONS:-}" = true ]; then printf '::%s::%s\n' "$1" "$2"; fi
  printf '%s: %s\n' "$1" "$2"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then printf -- '- **%s**: %s\n' "$1" "$2" >>"$GITHUB_STEP_SUMMARY"; fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "== specification releases"
for family in $(jq -r '.specifications | keys[]' "$ROOT/pins/pins.json"); do
  pinned=$(jq -r --arg f "$family" '.specifications[$f].version' "$ROOT/pins/pins.json")
  latest=$(curl -fsSL "$SPECS_HOST/$family/versions.json" | jq -r '.latest') \
    || { note error "could not read $SPECS_HOST/$family/versions.json"; status=1; continue; }
  if [ "$latest" = "$pinned" ]; then
    echo "ok   $family $pinned is the latest release"
  else
    note error "$family $latest is released; this repository pins $pinned. Run: scripts/pins/update.sh specifications $latest"
    status=1
  fi
done

echo "== live API ($LIVE_OPENAPI)"
if curl -fsSL "$LIVE_OPENAPI" -o "$TMP/live.json" && jq -e .paths "$TMP/live.json" >/dev/null 2>&1; then
  if python3 "$ROOT/scripts/check/api-routes.py" --openapi "$TMP/live.json" >"$TMP/routes.log" 2>&1; then
    echo "ok   every documented call is a route of the live API"
  else
    grep '^FAIL' "$TMP/routes.log" || true
    note error "a route the examples call is gone from the live API. Re-pin it (scripts/pins/update.sh openapi) and fix the calls"
    status=1
  fi
  if python3 "$ROOT/scripts/check/contract-test.py" --openapi "$TMP/live.json" >"$TMP/contract.log" 2>&1; then
    echo "ok   the live API's schemas accept everything musher-apply.sh sends"
  else
    grep -A3 '^FAIL' "$TMP/contract.log" || cat "$TMP/contract.log"
    note error "the live API's schemas refuse what musher-apply.sh sends. Re-pin it (scripts/pins/update.sh openapi) and fix the script"
    status=1
  fi
else
  note error "could not fetch $LIVE_OPENAPI"
  status=1
fi

exit $status
