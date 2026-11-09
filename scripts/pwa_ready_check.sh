#!/usr/bin/env bash
# PWA M6 (D-112): "ready for clients" check, run before the link goes to anyone.
# Usage: pwa_ready_check.sh --url https://host/ [--build-dir DIR] [--emulate]
#          [--attest login,scan,voice,offline,sync --device "TEXT" --operator NAME]
# Last line: "ready-check: GREEN" (exit 0), "RED" (exit 1) or "INCOMPLETE <what>" (exit 3). Bad input: exit 2.
# Runbook: docs/runbooks/mobile-web-pwa-ready-check.md. No login is automated and no password is taken.
set -u
url=""; build=""; emulate=0; attest=""; device=""; operator=""
while [ $# -gt 0 ]; do
  case "$1" in
    --url) url="${2:-}"; shift 2 ;;
    --build-dir) build="${2:-}"; shift 2 ;;
    --emulate) emulate=1; shift ;;
    --attest) attest="${2:-}"; shift 2 ;;
    --device) device="${2:-}"; shift 2 ;;
    --operator) operator="${2:-}"; shift 2 ;;
    *) echo "ready-check: unknown argument $1" >&2; exit 2 ;;
  esac
done
case "$url" in
  https://*[[:space:]]*|https://) echo "ready-check: --url must be an https:// address without spaces" >&2; exit 2 ;;
  https://*) ;;
  *) echo "ready-check: --url must be an https:// address" >&2; exit 2 ;;
esac
case "$url" in */) ;; *) url="$url/" ;; esac

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
bad=0; missing=""
pass() { echo "ready-check: PASS $1"; }
fail() { echo "ready-check: FAIL $1 ($2)"; bad=1; }

# probe PATH: sets code, ctype, and leaves body in $work/body, headers in $work/hdr (no -L: a redirect is a failure)
probe() {
  code="$(curl -sS --max-time 20 --retry 1 -D "$work/hdr" -o "$work/body" -w '%{http_code}' "${url}$1" 2>/dev/null)" || code="000"
  ctype="$(grep -i '^content-type:' "$work/hdr" 2>/dev/null | tail -1 | tr -d '\r' | tr 'A-Z' 'a-z')"
}

pass A1-https

probe ""
if [ "$code" = "200" ] && grep -q 'flutter_bootstrap.js' "$work/body"; then pass A2-index; else fail A2-index "status $code or no flutter_bootstrap.js"; fi
cp "$work/hdr" "$work/hdr_root"; cp "$work/body" "$work/index"

probe "manifest.json"
if [ "$code" = "200" ] && grep -q '"name"' "$work/body" && grep -q '"start_url"' "$work/body" && grep -q '"icons"' "$work/body"; then
  pass A3-manifest; else fail A3-manifest "status $code or name/start_url/icons missing"; fi
cp "$work/body" "$work/manifest"

probe "build-info.json"
if [ "$code" = "200" ] && grep -q '"sha"' "$work/body" && grep -Eq '"api_base_url"[[:space:]]*:[[:space:]]*"https://' "$work/body"; then
  pass A4-build-info; else fail A4-build-info "status $code, no sha, or api_base_url is not https"; fi

a5=0
for f in canvaskit/canvaskit.wasm zxing/zxing_reader.wasm; do
  probe "$f"
  if [ "$code" != "200" ] || ! printf '%s' "$ctype" | grep -q 'application/wasm'; then a5=1; echo "ready-check: detail $f status $code type '$ctype'"; fi
done
probe "zxing/zxing-config.js"
[ "$code" = "200" ] || { a5=1; echo "ready-check: detail zxing-config.js status $code"; }
if [ $a5 = 0 ]; then pass A5-wasm; else fail A5-wasm "wasm not served as application/wasm or zxing files missing"; fi

probe "fonts-fallback/x"
if [ "$code" = "404" ]; then pass A6-fonts-404; else fail A6-fonts-404 "status $code, must be a real 404"; fi

pp="$(grep -i '^permissions-policy:' "$work/hdr_root" | tr -d '\r' | tr 'A-Z' 'a-z')"
if printf '%s' "$pp" | grep -q 'camera=(self)' && printf '%s' "$pp" | grep -q 'microphone=(self)'; then
  pass A7-permissions-policy; else fail A7-permissions-policy "header missing camera=(self) or microphone=(self)"; fi

if grep -Eq '(src|href|url)[[:space:]]*[=:(][[:space:]]*["'"'"']?https?://' "$work/index" "$work/manifest"; then
  fail A8-no-other-host "index.html or manifest.json references another host"; else pass A8-no-other-host; fi

if [ -n "$build" ]; then
  if bash "$here/pwa_web_verify.sh" "$build"; then pass A9-build-verify; else fail A9-build-verify "pwa_web_verify.sh found defects"; fi
fi

# Emulation: the existing Flutter tests that cover login, scan, voice, offline queue and sync.
tests="test/auth/web_app_auth_adapter_test.dart test/features/codes/scan_screen_test.dart test/features/codes/camera_phase_test.dart test/guards/web_zxing_runtime_test.dart test/features/stock/web_voice_source_test.dart test/features/stock/voice_codec_test.dart test/offline/offline_queue_test.dart test/offline/offline_sync_test.dart"
if [ $emulate = 1 ]; then
  if ! command -v flutter >/dev/null 2>&1; then
    echo "ready-check: NOT RUN emulation (flutter not found)"; missing="$missing emulation-not-run"
  else
    # shellcheck disable=SC2086
    if (cd "$root/apps/mobile" && timeout 570 flutter test $tests >"$work/flutter.log" 2>&1); then pass E1-emulation
    else fail E1-emulation "flutter test failed or timed out"; tail -20 "$work/flutter.log"; fi
  fi
else
  missing="$missing emulation-not-run"
fi

# Device attestation: camera, microphone and airplane mode cannot be scripted.
okkeys=0
for k in login scan voice offline sync; do
  case ",$attest," in *",$k,"*) okkeys=$((okkeys+1)) ;; esac
done
extra="$(printf '%s' "$attest" | tr ',' '\n' | grep -vxE 'login|scan|voice|offline|sync' | grep -c . || true)"
if [ -n "$attest" ] && [ "$okkeys" != 5 ]; then missing="$missing attest-keys-incomplete"; fi
[ -z "$attest" ] && missing="$missing device-attestation"
[ "${extra:-0}" != 0 ] && missing="$missing attest-unknown-key"
[ -z "$device" ] && missing="$missing device-text"
[ -z "$operator" ] && missing="$missing operator-name"

if [ $bad = 1 ]; then echo "ready-check: RED"; exit 1; fi
if [ -n "$missing" ]; then echo "ready-check: INCOMPLETE$missing"; exit 3; fi
echo "ready-check: device: $device"
echo "ready-check: operator: $operator"
echo "ready-check: time: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "ready-check: GREEN"
exit 0
