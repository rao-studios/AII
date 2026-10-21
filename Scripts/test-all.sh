#!/bin/bash
# WHAT: Every test suite in this package — AIITests, AIICLITests, SeamTests, SewnTests,
#       ThreadTests — in one `swift test`, then a build of Examples/Notes, the import
#       demonstration, as a custom app builds it (AII by path, `traits: []`).
# PIN:  The servers' live tests want mlx.metallib copied into the xctest bundle AFTER building
#       (copying before breaks codesign; Scripts/test-local-sinatra.sh does it right); they stay
#       opt-in behind their SEWN_*_TESTS / THREAD_* variables and are not run here. Several
#       class names repeat across the suites (StackSecretTests, DataDirectoryTests, Flow1_*),
#       so a filter names its module: `swift test --filter 'SewnTests.StackSecretTests'`.
#       Building the example keeps it honest: a change that breaks what an app writes breaks here.
#
#   ./Scripts/test-all.sh
#   ./Scripts/test-all.sh 'ThreadTests.LaneIsolationTests'
#
set -euo pipefail
AII_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$AII_ROOT"
if [ $# -gt 0 ]; then
    swift test --filter "$1" 2>&1 | tail -5
else
    swift test 2>&1 | tail -5
    echo "Examples/Notes:"
    swift build --package-path Examples/Notes 2>&1 | tail -1
fi
