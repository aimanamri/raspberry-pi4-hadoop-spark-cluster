#!/usr/bin/env bash
# Render the recipes to GIF files with Pixelbolt (https://github.com/skulitom/Pixelbolt).
#   PIXELBOLT=/path/to/Pixelbolt/bin/pixelbolt.js ./render.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIXELBOLT="${PIXELBOLT:-$HOME/Desktop/Pixelbolt/bin/pixelbolt.js}"
SCALE="${SCALE:-5}"
cd "$HERE"
node build-recipes.mjs
for r in *.pixel.json; do
  name="${r%.pixel.json}"
  node "$PIXELBOLT" gif "$r" --out "../$name.gif" --scale "$SCALE" --force > /dev/null
  echo "wrote assets/$name.gif"
done
