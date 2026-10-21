#!/usr/bin/env bash
# Regenerates the Swift for Protos/*.proto:
#   thread.proto, fleet.proto -> Sources/Seam/Generated (public): the wire.
#   record.proto, lanes.proto -> Tests/AIITests/Generated (internal): only the conformance
#     tests read them. AII's own Swift forms (AIIRecord, AIILanes) are the API, so apps never
#     see a second envelope type.
#
# Both plugins are built from the root package's resolved checkouts (swift-protobuf,
# grpc-swift-protobuf), so the generated code always matches the runtime the package links
# against (a Homebrew-installed plugin can be a different version and produce code that
# doesn't compile). Requires protoc on PATH (brew install protobuf); runs at the AII root.
set -euo pipefail
cd "$(dirname "$0")/.."   # the AII root

SWIFT_PLUGIN=.build/plugin-build-swift/release/protoc-gen-swift
GRPC_PLUGIN=.build/plugin-build/release/protoc-gen-grpc-swift
if [[ ! -x "$SWIFT_PLUGIN" ]]; then
  swift package resolve
  swift build --package-path .build/checkouts/swift-protobuf \
    --product protoc-gen-swift -c release --scratch-path .build/plugin-build-swift
fi
if [[ ! -x "$GRPC_PLUGIN" ]]; then
  swift package resolve
  swift build --package-path .build/checkouts/grpc-swift-protobuf \
    --product protoc-gen-grpc-swift -c release --scratch-path .build/plugin-build
fi

SEAM=Sources/Seam/Generated
mkdir -p "$SEAM"
protoc --proto_path=Protos \
  --plugin=protoc-gen-swift="$SWIFT_PLUGIN" \
  --swift_out="$SEAM" --swift_opt=Visibility=Public \
  --plugin=protoc-gen-grpc-swift="$GRPC_PLUGIN" \
  --grpc-swift_out="$SEAM" \
  --grpc-swift_opt=Visibility=Public \
  --grpc-swift_opt=Server=true --grpc-swift_opt=Client=true \
  Protos/thread.proto Protos/fleet.proto
echo "Generated $(ls "$SEAM" | tr '\n' ' ')"

SCHEMA=Tests/AIITests/Generated
mkdir -p "$SCHEMA"
protoc --proto_path=Protos \
  --plugin=protoc-gen-swift="$SWIFT_PLUGIN" \
  --swift_out="$SCHEMA" --swift_opt=Visibility=Internal \
  Protos/record.proto Protos/lanes.proto
echo "Generated $(ls "$SCHEMA" | tr '\n' ' ')"
