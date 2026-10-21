#!/bin/bash
# WHAT: Build AIIServer — the one binary of the Ambient Intelligence Index, which runs as
#       `AIIServer sewn …` and `AIIServer thread …` — from this checkout, with the Metal
#       library MLX needs beside it.
# IN:   [debug|release] (default release). Frigate as SwiftPM resolved it, whose
#       build-metallib.sh produces mlx.metallib (found by Scripts/build-metallib.sh).
# OUT:  .build/<config>/{AIIServer,mlx.metallib}
# PIN:  The one place the server is built: the apps' scripts (Ambient's build-servers.sh
#       and make-app.sh, Craft's make-app.sh, Veil's run-stack.sh) call this and copy from
#       here. SwiftPM has no Metal step: Frigate's build-metallib.sh runs after
#       `swift build`, or the first on-device model load aborts inside MLX.
#
#   ./Scripts/build-servers.sh            # release
#   ./Scripts/build-servers.sh debug
#
set -euo pipefail

AII_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
case "$CONFIG" in debug|release) ;; *) echo "usage: $0 [debug|release]" >&2; exit 2 ;; esac

cd "$AII_ROOT"
echo "▸ swift build -c $CONFIG --product AIIServer"
swift build -c "$CONFIG" --product AIIServer
echo "▸ mlx.metallib ($CONFIG)"
"$AII_ROOT/Scripts/build-metallib.sh" "$CONFIG"
[ -x ".build/$CONFIG/AIIServer" ] || { echo "error: no AIIServer after the build" >&2; exit 1; }
[ -f ".build/$CONFIG/mlx.metallib" ] || { echo "error: no mlx.metallib beside AIIServer" >&2; exit 1; }
echo "  ready: $AII_ROOT/.build/$CONFIG/AIIServer"
