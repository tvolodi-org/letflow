#!/usr/bin/env bash
# PWA M5 (D-112): build, verify and package the Flutter web app (self-hosted CanvasKit, zxing, fonts).
# Env: PWA_API_BASE_URL (required, https only), PWA_BASE_HREF (default /), PWA_OUT (default apps/mobile/build/pwa).
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
api="${PWA_API_BASE_URL:-}"
base="${PWA_BASE_HREF:-/}"
out="${PWA_OUT:-$root/apps/mobile/build/pwa}"

if ! printf '%s' "$api" | grep -Eq '^https://[^/ ]+(/[^ ]*)?$'; then
  echo "pwa-build: PWA_API_BASE_URL must be an https:// URL without spaces (camera needs HTTPS), got '$api'" >&2
  exit 2
fi
if ! printf '%s' "$base" | grep -Eq '^/([^ ]*/)?$'; then
  echo "pwa-build: PWA_BASE_HREF must start and end with '/', got '$base'" >&2
  exit 2
fi

cd "$root/apps/mobile"
flutter pub get
flutter build web --release --no-web-resources-cdn --base-href "$base" \
  --dart-define=LETFLOW_API_BASE_URL="$api"
bash "$root/scripts/pwa_web_verify.sh" build/web
PWA_API_BASE_URL="$api" PWA_BASE_HREF="$base" bash "$root/scripts/pwa_web_package.sh" build/web "$out"
