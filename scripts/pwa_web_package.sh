#!/usr/bin/env bash
# PWA M5 (D-112): precompress, stamp and tar a verified Flutter web build.
# Usage: pwa_web_package.sh <build dir> <out dir>
# Env: GITHUB_SHA (else git HEAD), PWA_BASE_HREF, PWA_API_BASE_URL (recorded in build-info.json),
#      PWA_REQUIRE_BROTLI=1 (fail when brotli is missing).
set -eu
dir="${1:-}"; out="${2:-}"
if [ -z "$dir" ] || [ -z "$out" ] || [ ! -d "$dir" ]; then
  echo "usage: pwa_web_package.sh <build dir> <out dir>" >&2
  exit 2
fi

have_br=0
if command -v brotli >/dev/null 2>&1; then
  have_br=1
elif [ "${PWA_REQUIRE_BROTLI:-}" = "1" ]; then
  echo "pwa-package: brotli is required (PWA_REQUIRE_BROTLI=1) but not on PATH" >&2
  exit 1
else
  echo "pwa-package: warning: brotli not found, only .gz files are written" >&2
fi

sha="${GITHUB_SHA:-$(git rev-parse HEAD)}"
built_at="$(git show -s --format=%cI "$sha" 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"

# build-info.json first, so it is listed and compressed like the rest.
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
printf '{"sha":"%s","built_at":"%s","base_href":"%s","api_base_url":"%s"}\n' \
  "$(json_escape "$sha")" "$(json_escape "$built_at")" \
  "$(json_escape "${PWA_BASE_HREF:-/}")" "$(json_escape "${PWA_API_BASE_URL:-}")" >"$dir/build-info.json"

# Checksums of the uncompressed files (compressed siblings are derived data).
rm -f "$dir/SHA256SUMS"
(cd "$dir" && find . -type f ! -name '*.gz' ! -name '*.br' ! -name SHA256SUMS | sed 's|^\./||' | LC_ALL=C sort \
  | while IFS= read -r f; do sha256sum -- "$f"; done >SHA256SUMS)

# Precompress; keep a compressed file only when it is smaller.
find "$dir" -type f \( -name '*.js' -o -name '*.wasm' -o -name '*.json' -o -name '*.html' -o -name '*.css' \
  -o -name '*.txt' -o -name '*.symbols' -o -name '*.svg' -o -name '*.otf' -o -name '*.ttf' -o -name '*.bin' \) \
  -size +0c | while IFS= read -r f; do
  orig=$(wc -c <"$f")
  gzip -9 -k -n -f -- "$f"
  if [ "$(wc -c <"$f.gz")" -ge "$orig" ]; then rm -f -- "$f.gz"; fi
  if [ "$have_br" = 1 ]; then
    brotli -q 11 -k -f -- "$f"
    if [ "$(wc -c <"$f.br")" -ge "$orig" ]; then rm -f -- "$f.br"; fi
  fi
done

mkdir -p "$out"
tarfile="$out/letflow-pwa-web-$(printf '%s' "$sha" | cut -c1-12).tar"
tar -cf "$tarfile" -C "$dir" .
cp "$dir/SHA256SUMS" "$dir/build-info.json" "$out/"
echo "pwa-package: wrote $tarfile"
