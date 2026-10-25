#!/bin/zsh
# Rebuilds the README images: HTML rendered by Google Chrome through Playwright (pip install playwright;
# it drives the installed Chrome). No server, no GPU. Writes Docs/README_Assets/{hero,stack,join-guide,
# thread-search,sewn-turn,seam-wire}.png (build.py) and {sewn-thread-seam,thread-inside,partition-index-1,partition-index-2,first-index,lineage,credibility,threads,funnel,pin-board,training,lookup-tables}.png
# (plates.py); name targets to rebuild only those (e.g. `build.sh hero partition_index_search`).
set -euo pipefail
repo=${0:A:h:h:h:h}
cd "$repo"
plates=(sewn_thread_seam thread_inside partition_index_filing partition_index_search first_index lineage credibility threads funnel pins training lut)
sheets=() ours=()
for target in "$@"; do
  if (( ${plates[(Ie)$target]} )); then ours+=$target; else sheets+=$target; fi
done
if (( $# == 0 || ${#sheets} )); then python3 -I Docs/README_Assets/src/build.py Docs/README_Assets $sheets; fi
if (( $# == 0 || ${#ours} )); then python3 -I Docs/README_Assets/src/plates.py Docs/README_Assets $ours; fi
