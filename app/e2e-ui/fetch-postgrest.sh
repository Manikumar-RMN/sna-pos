#!/usr/bin/env bash
# Downloads the PostgREST binary the browser tests use (the same program Supabase runs for its REST API) into app/.tools/postgrest.
# It is fetched straight from the public Docker Hub image, one 5 MB layer; no Docker needed. Safe to run again.
# Usage: app/e2e-ui/fetch-postgrest.sh [version]        (default v12.2.12)
set -euo pipefail
VER="${1:-v12.2.12}"
DEST="$(cd "$(dirname "$0")/.." && pwd)/.tools"
case "$(uname -m)" in x86_64|amd64) ARCH=amd64;; aarch64|arm64) ARCH=arm64;; *) echo "unsupported CPU $(uname -m)"; exit 2;; esac
mkdir -p "$DEST"; [ -x "$DEST/postgrest" ] && "$DEST/postgrest" --version | grep -q "${VER#v}" && { echo "already have $("$DEST/postgrest" --version)"; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
tok() { curl -fsS "https://auth.docker.io/token?service=registry.docker.io&scope=repository:postgrest/postgrest:pull" | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])"; }
get() { curl -fsSL --retry 4 --retry-delay 3 -H "Authorization: Bearer $(tok)" -H "Accept: $2" "https://registry-1.docker.io/v2/postgrest/postgrest/$1"; }
IDX=$(get "manifests/$VER" "application/vnd.oci.image.index.v1+json")
DIGEST=$(printf '%s' "$IDX" | python3 -c "import sys,json;print([m['digest'] for m in json.load(sys.stdin)['manifests'] if m['platform']['architecture']=='$ARCH'][0])")
LAYER=$(get "manifests/$DIGEST" "application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json" | python3 -c "import sys,json;print(json.load(sys.stdin)['layers'][0]['digest'])")
curl -fsSL --retry 4 --retry-delay 3 -H "Authorization: Bearer $(tok)" "https://registry-1.docker.io/v2/postgrest/postgrest/blobs/$LAYER" -o "$TMP/layer.tgz"
tar xzf "$TMP/layer.tgz" -C "$TMP" ./bin/postgrest
install -m 755 "$TMP/bin/postgrest" "$DEST/postgrest"
"$DEST/postgrest" --version
