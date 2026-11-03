#!/usr/bin/env bash
# Screenshot a harness screen with headless Firefox (task S0d). See docs/design-system/screenshots.md.
#
#   web/scripts/screenshot.sh <screen> <out.png> [width] [height]
#       one shot; theme, language and state come from LF_SHOT_THEME (light|dark), LF_SHOT_LANG (en|ru|kk),
#       LF_SHOT_STATE (default|empty|loading|error); defaults light, en, default. 1440x900 unless given.
#   web/scripts/screenshot.sh --all <screen> [state]
#       widths 1440 and 390 x themes light and dark x languages en, ru, kk, into
#       ${TEAM_TASKDIR:-.}/shots/<screen>-<lang if not en>-<theme>-<width>.png
#
# Starts the Vite dev server on a free port, never uses the default Firefox profile (a fresh temporary one is
# made and removed), 90 s limit per shot, installs nothing. The dev server and the profile are cleaned up on
# every exit path.
set -u

START_DIR="$PWD"
WEB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHOT_TIMEOUT=90
START_TIMEOUT=60

usage() {
  sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

[ $# -ge 1 ] || usage
MODE=one
if [ "$1" = "--all" ]; then
  MODE=all
  shift
  [ $# -ge 1 ] || usage
  SCREEN="$1"
  ALL_STATE="${2:-default}"
else
  [ $# -ge 2 ] || usage
  SCREEN="$1"
  OUT="$2"
  WIDTH="${3:-1440}"
  HEIGHT="${4:-900}"
fi

case "$SCREEN" in
  *[!a-zA-Z0-9_-]*|'') echo "screenshot.sh: bad screen name: $SCREEN" >&2; exit 2 ;;
esac

FIREFOX="${FIREFOX:-firefox}"
command -v "$FIREFOX" >/dev/null 2>&1 || { echo "screenshot.sh: firefox not found" >&2; exit 1; }

SERVER_PID=""
PROFILE_DIR=""
LOG_FILE=""

cleanup() {
  if [ -n "$SERVER_PID" ]; then
    # npx starts node as a child: stop the whole process group of the server.
    kill -- "-$SERVER_PID" 2>/dev/null || kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
  fi
  [ -n "$PROFILE_DIR" ] && rm -rf "$PROFILE_DIR"
  [ -n "$LOG_FILE" ] && rm -f "$LOG_FILE"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

free_port() {
  python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

PORT="$(free_port)" || { echo "screenshot.sh: no free port" >&2; exit 1; }
LOG_FILE="$(mktemp)"

cd "$WEB_DIR" || exit 1
# setsid: own process group, so cleanup can stop npx and its node child together.
VITE_PORT="$PORT" setsid npx vite --host 127.0.0.1 --port "$PORT" --strictPort >"$LOG_FILE" 2>&1 &
SERVER_PID=$!

BASE="http://127.0.0.1:$PORT"
up=0
for _ in $(seq 1 "$START_TIMEOUT"); do
  if curl -fs -o /dev/null "$BASE/" 2>/dev/null; then up=1; break; fi
  kill -0 "$SERVER_PID" 2>/dev/null || break
  sleep 1
done
if [ "$up" != 1 ]; then
  echo "screenshot.sh: dev server did not answer on $BASE" >&2
  tail -n 20 "$LOG_FILE" >&2
  exit 1
fi

# shoot <theme> <lang> <state> <width> <height> <out.png>
shoot() {
  local theme="$1" lang="$2" state="$3" width="$4" height="$5" out="$6"
  local url="$BASE/__harness/$SCREEN?theme=$theme&lang=$lang&state=$state"
  mkdir -p "$(dirname "$out")"
  PROFILE_DIR="$(mktemp -d)"   # must exist or Firefox hangs
  timeout "$SHOT_TIMEOUT" "$FIREFOX" --headless --no-remote --profile "$PROFILE_DIR" \
    --screenshot "$out" --window-size="$width,$height" "$url" >/dev/null 2>&1
  local rc=$?
  rm -rf "$PROFILE_DIR"
  PROFILE_DIR=""
  if [ $rc -ne 0 ] || [ ! -s "$out" ]; then
    echo "screenshot.sh: Firefox failed (exit $rc) for $url" >&2
    return 1
  fi
  echo "$out"
}

if [ "$MODE" = one ]; then
  case "$OUT" in /*) ;; *) OUT="$START_DIR/$OUT" ;; esac
  shoot "${LF_SHOT_THEME:-light}" "${LF_SHOT_LANG:-en}" "${LF_SHOT_STATE:-default}" "$WIDTH" "$HEIGHT" "$OUT"
  exit $?
fi

SHOTS_DIR="${TEAM_TASKDIR:-.}/shots"
case "$SHOTS_DIR" in /*) ;; *) SHOTS_DIR="$START_DIR/$SHOTS_DIR" ;; esac
rc_all=0
for width in 1440 390; do
  height=900
  [ "$width" = 390 ] && height=844
  for theme in light dark; do
    for lang in en ru kk; do
      name="$SCREEN"
      [ "$lang" != en ] && name="$name-$lang"
      shoot "$theme" "$lang" "$ALL_STATE" "$width" "$height" "$SHOTS_DIR/$name-$theme-$width.png" || rc_all=1
    done
  done
done
exit $rc_all
