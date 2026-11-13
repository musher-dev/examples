#!/bin/sh
#
# Verify the vendored contracts in pins/ against the checksums in
# pins/pins.json, so a hand edit to a schema or to the OpenAPI copy, or a pin
# bumped without its file (or the reverse), fails CI.
#
# For a schema the checksum is the one the specifications project publishes
# beside the release (<url>.sha256, and its published.json ledger), so it can
# be checked independently of this repository.
#
#   Usage: scripts/pins/verify.sh

set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
PINS="$ROOT/pins"
status=0

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# check <label> <file relative to pins/> <expected sha256>
check() {
  if [ ! -f "$PINS/$2" ]; then
    printf 'FAIL %s: pins/%s is missing\n' "$1" "$2"; status=1; return
  fi
  actual=$(sha256 "$PINS/$2")
  if [ "$actual" = "$3" ]; then
    printf 'ok   %s: pins/%s\n' "$1" "$2"
  else
    printf 'FAIL %s: pins/%s has sha256 %s, pins.json says %s\n' "$1" "$2" "$actual" "$3"
    printf '     Do not edit vendored files. Re-vendor with scripts/pins/update.sh.\n'
    status=1
  fi
}

for family in $(jq -r '.specifications | keys[]' "$PINS/pins.json"); do
  file=$(jq -r --arg f "$family" '.specifications[$f].file' "$PINS/pins.json")
  check "$family schema $(jq -r --arg f "$family" '.specifications[$f].version' "$PINS/pins.json")" \
    "$file" "$(jq -r --arg f "$family" '.specifications[$f].sha256' "$PINS/pins.json")"
  # A bundle's $id is the URL it is served at, so it names its own release.
  url=$(jq -r --arg f "$family" '.specifications[$f].url' "$PINS/pins.json")
  id=$(jq -r '."$id" // ""' "$PINS/$file" 2>/dev/null || true)
  if [ "$id" != "$url" ]; then
    printf 'FAIL %s schema: its id is %s, pins.json pins %s\n' "$family" "$id" "$url"; status=1
  fi
done

check "openapi ($(jq -r '.openapi.pinnedOn' "$PINS/pins.json"))" \
  "$(jq -r '.openapi.file' "$PINS/pins.json")" "$(jq -r '.openapi.sha256' "$PINS/pins.json")"

exit $status
