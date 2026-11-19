#!/usr/bin/env bash
# REQ-868 (G16 part 2): signed Android release build (APK + AAB) and release manifest latest.json.
# Never signs with the debug key; never prints key.properties values. See
# docs/runbooks/mobile-android-release.md.
#
# Exit codes: 0 ok, 1 build/verification failure, 2 refused before building (bad input).
#
# Test hooks (env, all optional): ANDROID_RELEASE_MOBILE_DIR (default <repo>/apps/mobile),
# ANDROID_RELEASE_REPO_ROOT (default: parent of scripts/), used for the "--out not inside the repo" rule.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${ANDROID_RELEASE_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
MOBILE_DIR="${ANDROID_RELEASE_MOBILE_DIR:-$REPO_ROOT/apps/mobile}"
BUILD_KEY="$MOBILE_DIR/android/key.properties"
KEY_PROPS="$BUILD_KEY"
CUSTOM_KEY=0 BACKUP_KEY=""
NAME_PREFIX="letflow"

OUT="" BASE_URL="" API_URL="" PLATFORM_HOST="" MIN_CODE="" NOTES_FILE=""
LAST_PUBLISHED="" FIRST_RELEASE=0 DRY_RUN=0

die() { echo "android_release_build: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="${2:-}"; shift 2 ;;
    --base-url) BASE_URL="${2:-}"; shift 2 ;;
    --api-base-url) API_URL="${2:-}"; shift 2 ;;
    --platform-host) PLATFORM_HOST="${2:-}"; shift 2 ;;
    --min-version-code) MIN_CODE="${2:-}"; shift 2 ;;
    --notes-file) NOTES_FILE="${2:-}"; shift 2 ;;
    --last-published) LAST_PUBLISHED="${2:-}"; shift 2 ;;
    --first-release) FIRST_RELEASE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --name-prefix) NAME_PREFIX="${2:-}"; shift 2 ;;
    --key-properties) KEY_PROPS="${2:-}"; CUSTOM_KEY=1; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done

# --- checks that refuse without building (exit 2) ---------------------------------------------
[ -n "$OUT" ] || die "--out DIR is required"
[ -n "$BASE_URL" ] || die "--base-url URL is required"
case "$BASE_URL" in https://*) ;; *) die "--base-url must be an https URL" ;; esac
if [ -n "$API_URL" ]; then
  case "$API_URL" in https://*) ;; *) die "--api-base-url must be an https URL" ;; esac
fi

case "$NAME_PREFIX" in ''|*[!A-Za-z0-9._-]*|-*|.*) die "--name-prefix must be non-empty and use only letters, digits, . _ - (not starting with - or .)" ;; esac
[ "$CUSTOM_KEY" -eq 0 ] || [ -n "$KEY_PROPS" ] || die "--key-properties needs a file"

mkdir -p "$OUT" || die "cannot create --out"
OUT="$(cd "$OUT" && pwd -P)"
REPO_REAL="$(cd "$REPO_ROOT" && pwd -P)"
case "$OUT/" in "$REPO_REAL"/*) die "--out must be outside the repository" ;; esac

# Key file: only the presence of the four keys is checked; values are never read into output.
[ -f "$KEY_PROPS" ] || die "key.properties not found at $KEY_PROPS (see docs/runbooks/mobile-android-release.md)"
for k in storeFile storePassword keyAlias keyPassword; do
  grep -Eq "^[[:space:]]*$k[[:space:]]*=[[:space:]]*[^[:space:]]" "$KEY_PROPS" \
    || die "key.properties is missing a value for $k"
done

VERSION_LINE="$(grep -E '^version:' "$MOBILE_DIR/pubspec.yaml" | head -n1 | sed -E 's/^version:[[:space:]]*//; s/[[:space:]]+$//')"
VERSION_NAME="${VERSION_LINE%%+*}"
VERSION_CODE="${VERSION_LINE#*+}"
case "$VERSION_CODE" in ''|*[!0-9]*) die "pubspec.yaml version line has no +<versionCode>" ;; esac
[ -n "$VERSION_NAME" ] || die "pubspec.yaml version line has no versionName"

MANIFEST="$OUT/latest.json"
PREV_CODE="" PREV_MIN=""
if [ -f "$MANIFEST" ]; then
  PREV_CODE="$(python3 -I -c 'import json,sys; print(int(json.load(open(sys.argv[1]))["versionCode"]))' "$MANIFEST" 2>/dev/null)" \
    || die "$MANIFEST is not a valid release manifest"
  PREV_MIN="$(python3 -I -c 'import json,sys; print(int(json.load(open(sys.argv[1])).get("minVersionCode",1)))' "$MANIFEST" 2>/dev/null)" || PREV_MIN=""
elif [ -n "$LAST_PUBLISHED" ]; then
  case "$LAST_PUBLISHED" in ''|*[!0-9]*) die "--last-published must be a number" ;; esac
  PREV_CODE="$LAST_PUBLISHED"
elif [ "$FIRST_RELEASE" -ne 1 ]; then
  die "no $MANIFEST and no --last-published: pass --last-published N or --first-release"
fi
if [ -n "$PREV_CODE" ] && [ "$VERSION_CODE" -le "$PREV_CODE" ]; then
  die "version code $VERSION_CODE is not higher than the last published $PREV_CODE (raise the number after + in apps/mobile/pubspec.yaml)"
fi

if [ -z "$MIN_CODE" ]; then MIN_CODE="${PREV_MIN:-1}"; fi
case "$MIN_CODE" in ''|*[!0-9]*) die "--min-version-code must be a number" ;; esac
if [ -n "$NOTES_FILE" ] && [ ! -f "$NOTES_FILE" ]; then die "--notes-file not found"; fi

NAME="$NAME_PREFIX-$VERSION_NAME-$VERSION_CODE"
DEFINES=()
[ -n "$API_URL" ] && DEFINES+=("--dart-define=LETFLOW_API_BASE_URL=$API_URL")
if [ -n "$PLATFORM_HOST" ]; then
  DEFINES+=("--dart-define=LETFLOW_PLATFORM_HOST=$PLATFORM_HOST" "-Pplatform-host=$PLATFORM_HOST")
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "dry-run: version $VERSION_NAME ($VERSION_CODE), output $OUT/$NAME.{apk,apk.sha256,aab}, latest.json"
  echo "dry-run: (cd apps/mobile && flutter build apk --release ${DEFINES[*]:-})"
  echo "dry-run: (cd apps/mobile && flutter build appbundle --release ${DEFINES[*]:-})"
  echo "dry-run: apksigner verify --print-certs $NAME.apk"
  exit 0
fi

# --- build -------------------------------------------------------------------------------------
command -v flutter >/dev/null 2>&1 || { echo "android_release_build: flutter not found on PATH" >&2; exit 1; }
cd "$MOBILE_DIR" || exit 1
# --key-properties: the file sits at the fixed build path only for the build; an existing file there is
# put back afterwards. Nothing is printed.
restore_key() {
  rm -f "$BUILD_KEY"
  if [ -n "$BACKUP_KEY" ] && [ -f "$BACKUP_KEY" ]; then mv -f "$BACKUP_KEY" "$BUILD_KEY"; fi
}
if [ "$CUSTOM_KEY" -eq 1 ]; then
  mkdir -p "$(dirname "$BUILD_KEY")"
  if [ -f "$BUILD_KEY" ]; then
    BACKUP_KEY="$BUILD_KEY.bak.$$"
    mv -f "$BUILD_KEY" "$BACKUP_KEY" || exit 1
  fi
  trap restore_key EXIT
  cp "$KEY_PROPS" "$BUILD_KEY" && chmod 600 "$BUILD_KEY" || exit 1
fi
flutter build apk --release "${DEFINES[@]}" || { echo "android_release_build: apk build failed" >&2; exit 1; }
flutter build appbundle --release "${DEFINES[@]}" || { echo "android_release_build: appbundle build failed" >&2; exit 1; }

APK_SRC="$MOBILE_DIR/build/app/outputs/flutter-apk/app-release.apk"
AAB_SRC="$MOBILE_DIR/build/app/outputs/bundle/release/app-release.aab"
[ -f "$APK_SRC" ] && [ -f "$AAB_SRC" ] || { echo "android_release_build: build outputs not found" >&2; exit 1; }

# --- verify the signature: never publish a debug-signed APK -------------------------------------
APKSIGNER="$(command -v apksigner || true)"
if [ -z "$APKSIGNER" ]; then
  for root in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}"; do
    [ -n "$root" ] || continue
    cand="$(ls -d "$root"/build-tools/*/apksigner 2>/dev/null | sort -V | tail -n1)"
    [ -n "$cand" ] && APKSIGNER="$cand" && break
  done
fi
[ -n "$APKSIGNER" ] || { echo "android_release_build: apksigner not found (set ANDROID_HOME)" >&2; exit 1; }
CERTS="$("$APKSIGNER" verify --print-certs "$APK_SRC" 2>&1)" \
  || { echo "android_release_build: apksigner verify failed" >&2; exit 1; }
if printf '%s\n' "$CERTS" | grep -q 'CN=Android Debug'; then
  echo "android_release_build: the APK is signed with the Android debug certificate; refusing" >&2
  exit 1
fi

# --- outputs -----------------------------------------------------------------------------------
cp "$APK_SRC" "$OUT/$NAME.apk" && cp "$AAB_SRC" "$OUT/$NAME.aab" || exit 1
SHA="$(sha256sum "$OUT/$NAME.apk" | cut -d' ' -f1)"
printf '%s\n' "$SHA" > "$OUT/$NAME.apk.sha256"

python3 -I - "$MANIFEST" "$VERSION_CODE" "$VERSION_NAME" "${BASE_URL%/}/$NAME.apk" "$SHA" "$MIN_CODE" "$NOTES_FILE" <<'PY' || exit 1
import json, sys, datetime
path, code, name, url, sha, minc, notes_file = sys.argv[1:8]
notes = {"ru": "", "kk": "", "en": ""}
if notes_file:
    for line in open(notes_file, encoding="utf-8"):
        k, _, v = line.partition(":")
        if k.strip() in notes:
            notes[k.strip()] = v.strip()
doc = {
    "versionCode": int(code), "versionName": name, "url": url, "sha256": sha,
    "minVersionCode": int(minc), "notes": notes,
    "published": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
open(path, "w", encoding="utf-8").write(json.dumps(doc, ensure_ascii=False, indent=2) + "\n")
PY
echo "android_release_build: wrote $NAME.apk, $NAME.apk.sha256, $NAME.aab, latest.json in $OUT"
