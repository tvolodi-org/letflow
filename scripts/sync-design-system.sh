#!/usr/bin/env bash
# Copy the Letflow platform design system's living style guide into web/public/design-system/,
# so the web build ships it at /design-system/ (no sign-in, no tenant, no React route).
#
# Usage:
#   scripts/sync-design-system.sh           refresh web/public/design-system/ from the design repo
#   scripts/sync-design-system.sh --check   fail when the committed copy differs from what a
#                                           fresh sync of the design repo would produce
# Env: DESIGN_REPO (default /home/tvolodi/dev/ai-dala/letflow-design, read-only, never edited).
#
# The copy is a release artifact: never edit it by hand. Values (tokens.css, components.css, logo
# files) come through the design repo's own core/tools/release.sh; the pages are copied from
# platform/style-guide and platform/examples with only these mechanical changes:
#   - the stylesheet/script/link paths are rewritten to the flat layout below;
#   - <meta name="robots" content="noindex"> is added to every page;
#   - the style guide gets one header line naming the copy date.
# Layout: index.html (style guide), demo.js, css/, img/, examples/{org-units,codes,import}.html,
# examples/nav-strings.js, MANIFEST.sha256 (hashes of every file; web/tests/unit/designSystemCopy
# checks it, so a hand edit fails the web gate even where the design repo is absent).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
DESIGN="${DESIGN_REPO:-/home/tvolodi/dev/ai-dala/letflow-design}"
DEST="$REPO_ROOT/web/public/design-system"
MODE="${1:-sync}"

[ -x "$DESIGN/core/tools/release.sh" ] || { echo "design repo not found at $DESIGN (set DESIGN_REPO)" >&2; exit 2; }

build() { # build <target-dir>
  local T="$1"
  rm -rf "$T"; mkdir -p "$T/examples"
  bash "$DESIGN/core/tools/release.sh" platform "$T" >/dev/null
  cp "$DESIGN/platform/style-guide/demo.js" "$T/demo.js"
  cp "$DESIGN/platform/examples/nav-strings.js" "$T/examples/nav-strings.js"
  local DATE
  DATE="$(git -C "$DESIGN" log -1 --format=%cs 2>/dev/null || date -u +%F)"
  local META='<meta name="robots" content="noindex">'
  # style guide: ../tokens.css -> css/tokens.css ; components.css -> css/components.css ;
  # ../examples/ -> examples/
  sed -e 's#href="\.\./tokens\.css"#href="css/tokens.css"#' \
      -e 's#href="components\.css"#href="css/components.css"#' \
      -e 's#href="\.\./examples/#href="examples/#g' \
      -e "s#<meta charset=\"utf-8\">#&\n$META#" \
      -e "s#^<main class=\"sg\">#&\n<p class=\"eyebrow\">Letflow platform design system, copy of $DATE of letflow-design</p>#" \
      "$DESIGN/platform/style-guide/index.html" > "$T/index.html"
  local f
  for f in org-units codes import; do
    sed -e 's#href="\.\./tokens\.css"#href="../css/tokens.css"#' \
        -e 's#href="\.\./style-guide/components\.css"#href="../css/components.css"#' \
        -e 's#src="\.\./style-guide/demo\.js"#src="../demo.js"#' \
        -e "s#<meta charset=\"utf-8\">#&\n$META#" \
        "$DESIGN/platform/examples/$f.html" > "$T/examples/$f.html"
  done
  # Every page must carry the noindex meta and no stale path (the charset line is what we anchor on).
  for f in index.html examples/org-units.html examples/codes.html examples/import.html; do
    grep -q 'name="robots" content="noindex"' "$T/$f" || { echo "sync: $f has no charset line to anchor noindex" >&2; exit 1; }
  done
  (cd "$T" && find . -type f ! -name MANIFEST.sha256 | LC_ALL=C sort | xargs sha256sum > MANIFEST.sha256)
}

case "$MODE" in
  sync)
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    build "$TMP/out"
    rm -rf "$DEST"; mkdir -p "$(dirname "$DEST")"; cp -r "$TMP/out" "$DEST"
    echo "synced design system into web/public/design-system/" ;;
  --check)
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    build "$TMP/out"
    if diff -r "$TMP/out" "$DEST" >/dev/null; then echo "design-system copy is up to date"
    else diff -r "$TMP/out" "$DEST" | head -20 >&2; echo "design-system copy differs from $DESIGN: run scripts/sync-design-system.sh" >&2; exit 1; fi ;;
  *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac
