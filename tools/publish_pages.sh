#!/usr/bin/env bash
# Publish the web build to GitHub Pages: https://simonalkemade.github.io/GrandTheftAmsterdam/
#
#   tools/publish_pages.sh            export, assemble, push the gh-pages branch
#   tools/publish_pages.sh --no-push  export and assemble only (the site is left in $SITE)
#
# The site is godot-city/web/play.html as index.html, the engine and game pack
# Godot exports, and the city tiles the game streams (they stay out of the pack).
# gh-pages holds one commit, replaced on every publish, so the repo does not
# grow by the size of the site each time. GODOT names the Godot 4.4 binary.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GODOT="${GODOT:-godot}"
SITE="${SITE:-$ROOT/web-build/site}"
BUILD="$ROOT/web-build"

mkdir -p "$BUILD"
"$GODOT" --headless --path "$ROOT/godot-city" --export-release "Web" "$BUILD/index.html"

rm -rf "$SITE"
mkdir -p "$SITE/engine" "$SITE/data" "$SITE/data-compact"
cp "$BUILD"/index.js "$BUILD"/index.wasm "$BUILD"/index.pck "$BUILD"/index.audio*.worklet.js "$SITE/engine/"
cp -r "$ROOT/godot-city/data/tiles" "$ROOT/godot-city/data/overview.jpg" "$SITE/data/"
cp -r "$ROOT/godot-city/data-compact/tiles" "$ROOT/godot-city/data-compact/overview.jpg" "$SITE/data-compact/"
WASM=$(stat -c %s "$BUILD/index.wasm" 2>/dev/null || stat -f %z "$BUILD/index.wasm")
PCK=$(stat -c %s "$BUILD/index.pck" 2>/dev/null || stat -f %z "$BUILD/index.pck")
sed "s/@WASM@/$WASM/g; s/@PCK@/$PCK/g" "$ROOT/godot-city/web/play.html" > "$SITE/index.html"
touch "$SITE/.nojekyll"
echo "site: $SITE ($(du -sh "$SITE" | cut -f1))"

[ "${1:-}" = "--no-push" ] && exit 0
REV=$(git -C "$ROOT" rev-parse --short HEAD)
URL=$(git -C "$ROOT" remote get-url origin)
cd "$SITE"
rm -rf .git
git init -q -b gh-pages
git add -A .
git -c user.name="$(git -C "$ROOT" config user.name)" -c user.email="$(git -C "$ROOT" config user.email)" \
	commit -q -m "Web build of $REV"
git fetch -q "$URL" gh-pages 2>/dev/null && LEASE="--force-with-lease=gh-pages:$(git rev-parse FETCH_HEAD)" || LEASE=""
git push -q $LEASE "$URL" gh-pages
rm -rf .git
echo "pushed gh-pages ($REV): https://simonalkemade.github.io/GrandTheftAmsterdam/"
