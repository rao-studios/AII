#!/bin/bash
# WHAT: Run Sewn's on-device SinatraHarness (Frigate's product) tests, the live two-turn test included.
# IN:   SEWN_LOCAL_SINATRA_MODEL to pick the model (default Mistral Small 3.2 4-bit).
# PIN:  The test bundles are code-signed at build time and a metallib copied into them breaks
#       the seal, so it is removed before the build and installed after (Frigate's script fills
#       every *.xctest beside the binaries).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
for bundle in .build/debug/*.xctest; do
  [ -d "$bundle" ] || continue
  rm -f "$bundle/Contents/MacOS/mlx.metallib"
  rm -rf "$bundle/Contents/MacOS/Resources"
done
swift build --build-tests
"$ROOT/Scripts/build-metallib.sh" debug > /dev/null
SEWN_LOCAL_SINATRA_TESTS=1 swift test --skip-build --filter "SewnTests.LocalSinatra" "$@"
