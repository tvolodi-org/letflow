#!/usr/bin/env bash
# PWA M6 (D-112): fill the link and the feedback address into the three client scripts.
# Usage: pwa_client_kit_render.sh --link https://host/ --email name@host.tld --out DIR
# Writes script.{en,ru,kk}.md into the new/empty DIR (keep it outside git). Sends nothing. Exit 2 on bad input.
set -u
link=""; email=""; out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --link) link="${2:-}"; shift 2 ;;
    --email) email="${2:-}"; shift 2 ;;
    --out) out="${2:-}"; shift 2 ;;
    *) echo "render: unknown argument $1" >&2; exit 2 ;;
  esac
done
die() { echo "render: $1" >&2; exit 2; }
case "$link" in https://*[[:space:]]*|https://|"") die "--link must be an https:// address without spaces" ;; https://*) ;; *) die "--link must be an https:// address without spaces" ;; esac
printf '%s' "$email" | grep -Eq '^[^[:space:]?&"@%]+@[^[:space:]?&"@%]+\.[^[:space:]?&"@%]+$' || die "--email must look like name@host.tld (no spaces, ?, &, quotes)"
[ -n "$out" ] || die "--out is required"
if [ -e "$out" ] && [ -n "$(ls -A "$out" 2>/dev/null)" ]; then die "--out exists and is not empty"; fi
src="$(cd "$(dirname "$0")/.." && pwd)/docs/runbooks/pwa-client-test"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
for l in en ru kk; do
  awk -v link="$link" -v email="$email" '
    function rep(s, key, val,   i, r) { r = ""; while ((i = index(s, key)) > 0) { r = r substr(s, 1, i - 1) val; s = substr(s, i + length(key)) } return r s }
    { print rep(rep($0, "@@OWNER_EMAIL@@", email), "@@LINK@@", link) }' "$src/script.$l.md" >"$tmp/script.$l.md" || die "cannot read script.$l.md"
  if grep -q '@@' "$tmp/script.$l.md"; then die "a placeholder remains in script.$l.md"; fi
done
mkdir -p "$out" && cp "$tmp"/script.*.md "$out"/ || die "cannot write $out"
echo "render: wrote 3 scripts to $out"
