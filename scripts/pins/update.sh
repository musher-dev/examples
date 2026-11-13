#!/bin/sh
#
# Bump a pinned contract: re-vendor it into pins/ and record it in
# pins/pins.json. Then run the checks; whatever the new contract breaks in the
# examples, the script or the READMEs is what the bump has to fix.
#
#   Usage:
#     scripts/pins/update.sh specifications <version>      e.g. 2.2.0
#         Downloads the component and blueprint schema bundles of that exact
#         release from specifications.musher.dev, and verifies each against
#         the .sha256 published beside it before writing it.
#
#     scripts/pins/update.sh openapi [<file-or-url>] [<source-label>]
#         Vendors the public OpenAPI description. Defaults to the published
#         one, https://api.musher.dev/openapi.json, which anyone can fetch.
#         Musher maintainers pin the copy in platform-api instead:
#           git -C ../platform-api show origin/main:platform-api/contracts/openapi/public.json \
#             > /tmp/public.json
#           scripts/pins/update.sh openapi /tmp/public.json \
#             "musher-dev/platform-api@$(git -C ../platform-api rev-parse origin/main):platform-api/contracts/openapi/public.json"
#         The file is stored with sorted keys and two-space indents, so a
#         bump's diff shows what changed in the API, not in the formatting.

set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
PINS="$ROOT/pins"
SPECS_HOST="https://specifications.musher.dev"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# set_pin <jq-path> <json-value>
set_pin() {
  jq --indent 2 "$1 = \$v" --argjson v "$2" "$PINS/pins.json" >"$TMP/pins.json"
  mv "$TMP/pins.json" "$PINS/pins.json"
}

case "${1:-}" in
  specifications)
    version="${2:-}"
    printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
      || die "give an exact release version, e.g. 2.1.0 (see $SPECS_HOST/component/versions.json)"
    for family in component blueprint; do
      url="$SPECS_HOST/$family/v$version/$family.schema.json"
      curl -fsSL "$url" -o "$TMP/$family.schema.json" || die "no $family release $version at $url"
      curl -fsSL "$url.sha256" -o "$TMP/$family.sha256" || die "no checksum at $url.sha256"
      expected=$(cut -d' ' -f1 <"$TMP/$family.sha256")
      actual=$(sha256 "$TMP/$family.schema.json")
      [ "$expected" = "$actual" ] || die "$url has sha256 $actual, but $url.sha256 says $expected"
      mv "$TMP/$family.schema.json" "$PINS/schemas/$family.schema.json"
      set_pin ".specifications.$family" "$(jq -n --arg v "$version" --arg u "$url" --arg s "$actual" \
        --arg f "schemas/$family.schema.json" '{version: $v, file: $f, url: $u, sha256: $s}')"
      printf 'pinned %s %s (%s)\n' "$family" "$version" "$actual"
    done
    ;;
  openapi)
    source="${2:-https://api.musher.dev/openapi.json}"
    label="${3:-$source}"
    case "$source" in
      https://*) curl -fsSL "$source" -o "$TMP/source.json" || die "could not fetch $source" ;;
      *) [ -f "$source" ] || die "no such file: $source"; cp "$source" "$TMP/source.json" ;;
    esac
    jq -e '.openapi and .paths' "$TMP/source.json" >/dev/null 2>&1 \
      || die "$source is not an OpenAPI description"
    jq -S --indent 2 . "$TMP/source.json" >"$PINS/openapi/public.json"
    set_pin ".openapi" "$(jq -n --arg src "$label" --arg ssha "$(sha256 "$TMP/source.json")" \
      --arg on "$(date -u +%Y-%m-%d)" --arg sha "$(sha256 "$PINS/openapi/public.json")" \
      '{file: "openapi/public.json", source: $src, sourceSha256: $ssha, pinnedOn: $on, sha256: $sha}')"
    printf 'pinned openapi from %s\n' "$label"
    ;;
  *)
    sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
    ;;
esac

cat <<EOF

Now run the checks and fix what they find:

  sh scripts/pins/verify.sh
  sh scripts/check/specs.sh
  python3 scripts/check/api-routes.py
  python3 scripts/check/contract-test.py
EOF
