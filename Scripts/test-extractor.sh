#!/bin/bash
# WHAT: The extractor's live test (ThreadTests.Flow33_ExtractorLiveTests): a real model read through the
#       gate — three source files for code relations, six readings at once, a paragraph extracted, the
#       model released — and the gate's own tests beside it.
# IN:   $1 or THREAD_EXTRACTOR_LIVE_MODEL: a Hub spec (org/repo@commit, e.g. AIIModels.generalSmall's
#       pinnedSpec, the extractor every Thread runs) or a model folder (a mirror checked before upload).
# PIN:  The test bundles are code-signed at build time and a metallib copied into them breaks the seal,
#       so it is removed before the build and installed after (as Scripts/test-local-sinatra.sh does).
#
#   ./Scripts/test-extractor.sh rao-studios/granite-4.0-h-micro-mlx-4bit@<commit>
#   ./Scripts/test-extractor.sh /path/to/a/model/folder
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
MODEL="${1:-${THREAD_EXTRACTOR_LIVE_MODEL:-}}"
if [ -z "$MODEL" ]; then
  echo "usage: $0 <org/repo@commit | model folder>   (or set THREAD_EXTRACTOR_LIVE_MODEL)" >&2
  exit 2
fi
for bundle in .build/debug/*.xctest; do
  [ -d "$bundle" ] || continue
  rm -f "$bundle/Contents/MacOS/mlx.metallib"
  rm -rf "$bundle/Contents/MacOS/Resources"
done
swift build --build-tests
"$ROOT/Scripts/build-metallib.sh" debug > /dev/null
THREAD_EXTRACTOR_LIVE_MODEL="$MODEL" swift test --skip-build --filter 'ThreadTests.Flow3[23]_' 2>&1 | grep -E '\[live\]|Test Case|passed|failed|error|Executed' 
