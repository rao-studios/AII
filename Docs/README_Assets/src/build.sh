#!/bin/zsh
# Rebuilds the README images: HTML rendered by Google Chrome through Playwright (pip install playwright;
# it drives the installed Chrome). No server, no GPU. Writes Docs/README_Assets/{hero,stack,join-guide,
# thread-search,sewn-turn,seam-wire}.png; name targets to rebuild only those (e.g. `build.sh hero stack`).
set -euo pipefail
repo=${0:A:h:h:h:h}
cd "$repo"
python3 -I Docs/README_Assets/src/build.py Docs/README_Assets "$@"
