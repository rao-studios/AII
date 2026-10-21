#!/usr/bin/env bash
# WHAT: Build MLX's mlx.metallib into this package's .build, beside AIIServer and inside the
#       test bundles.
# IN:   [debug|release] (default debug). Frigate's checkout: an edited one (Packages/Frigate,
#       from `swift package edit Frigate`), else SwiftPM's (.build/checkouts/Frigate);
#       FRIGATE_DIR overrides both.
# PIN:  A DELEGATE, NOT AN IMPLEMENTATION. Frigate owns the .metal sources, so it owns the
#       compile; hand-copied versions of this script drifted apart, so this one only points at
#       Frigate's. Scripts/build-servers.sh calls it after `swift build`.
#
#   ./Scripts/build-metallib.sh [debug|release]
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -z "${FRIGATE_DIR:-}" ]; then
    FRIGATE_DIR="$REPO_ROOT/.build/checkouts/Frigate"
    [ -d "$REPO_ROOT/Packages/Frigate" ] && FRIGATE_DIR="$REPO_ROOT/Packages/Frigate"
fi
CANONICAL="$FRIGATE_DIR/scripts/build-metallib.sh"

if [ ! -x "$CANONICAL" ]; then
    echo "build-metallib: cannot find $CANONICAL" >&2
    echo "  Run Scripts/setup.sh, or set FRIGATE_DIR to a Frigate checkout." >&2
    exit 1
fi

exec "$CANONICAL" "${1:-debug}" --package "$REPO_ROOT"
