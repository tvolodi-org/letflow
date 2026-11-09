#!/usr/bin/env bash
# PWA M5 (D-112): check that a Flutter web build is self-hosted (no CDN). Usage: pwa_web_verify.sh <build dir>
# Prints one "pwa-verify:" line per defect; exit 1 when there is any.
set -u
dir="${1:-}"
if [ -z "$dir" ] || [ ! -d "$dir" ]; then
  echo "pwa-verify: build directory missing: '$dir'" >&2
  exit 2
fi
bad=0
fail() { echo "pwa-verify: $1"; bad=1; }

for f in index.html flutter_bootstrap.js main.dart.js manifest.json canvaskit/canvaskit.wasm \
  zxing/zxing-reader.iife.js zxing/zxing_reader.wasm zxing/zxing-config.js; do
  [ -f "$dir/$f" ] || fail "missing file $f"
done

boot="$dir/flutter_bootstrap.js"
if [ -f "$boot" ]; then
  grep -q '"useLocalCanvasKit":true' "$boot" || fail "flutter_bootstrap.js does not set useLocalCanvasKit (CanvasKit would load from a CDN)"
  grep -q 'fontFallbackBaseUrl' "$boot" || fail "flutter_bootstrap.js does not set fontFallbackBaseUrl (fonts would load from gstatic)"
  # The loader code itself holds a dead gstatic default (used only without useLocalCanvasKit), so
  # only a font base set to an absolute http(s) URL is a defect.
  if grep -Eq 'fontFallbackBaseUrl[[:space:]]*:[[:space:]]*["'"'"']https?://' "$boot"; then
    fail "flutter_bootstrap.js sets fontFallbackBaseUrl to an absolute URL"
  fi
fi

fm="$dir/assets/FontManifest.json"
if [ -f "$fm" ]; then
  grep -q '"family":"Roboto"\|"family": "Roboto"' "$fm" || fail "FontManifest.json does not list family Roboto"
  for a in $(grep -o '"asset": *"[^"]*\.ttf"' "$fm" | sed 's/.*: *"\(.*\)"/\1/'); do
    [ -f "$dir/assets/$a" ] || fail "FontManifest.json names $a but assets/$a is missing"
  done
else
  fail "missing file assets/FontManifest.json"
fi

for f in index.html manifest.json zxing/zxing-config.js; do
  [ -f "$dir/$f" ] || continue
  if grep -Eq '(src|href|url)[[:space:]]*[=:(][[:space:]]*["'"'"']?https?://' "$dir/$f"; then
    fail "$f references another host over http(s)"
  fi
done

exit $bad
