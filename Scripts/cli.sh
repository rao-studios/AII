#!/bin/bash
# WHAT: Run aii from this checkout: build it when its sources are newer than the binary, then
#       exec it with your arguments. With none, in a terminal, that opens the studio — which is
#       what Scripts/aii.command runs.
# IN:   AII_CONFIG=debug|release (default debug); AII_SKIP_BUILD=1 reuses the last build.
# PIN:  Never changes your directory, so `Scripts/cli.sh install .` means this folder; build
#       chatter goes to stderr and aii's output to stdout. Follows its own symlinks.
#
#   ./Scripts/cli.sh status
#   AII_CONFIG=release ./Scripts/cli.sh doctor
#
set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
AII_ROOT="$(cd -P "$(dirname "$SOURCE")/.." && pwd)"
CONFIG="${AII_CONFIG:-debug}"
case "$CONFIG" in debug|release) ;; *) echo "usage: AII_CONFIG=debug|release $0 [aii arguments]" >&2; exit 64 ;; esac

BINARY="$(swift build --package-path "$AII_ROOT" -c "$CONFIG" --show-bin-path)/aii"
if [ "${AII_SKIP_BUILD:-0}" != 1 ]; then
    if [ ! -x "$BINARY" ] || [ -n "$(find "$AII_ROOT/Sources/AII" "$AII_ROOT/Sources/AIICLI" "$AII_ROOT/Sources/Seam" \
            "$AII_ROOT/Package.swift" -newer "$BINARY" -print -quit 2>/dev/null)" ]; then
        echo "▸ building aii ($CONFIG)" >&2
        swift build --package-path "$AII_ROOT" -c "$CONFIG" --product aii >&2
    fi
fi
exec "$BINARY" "$@"
