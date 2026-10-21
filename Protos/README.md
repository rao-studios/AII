# Protos: the schemas

[← the stack](../README.md) · [AII](../Docs/AII/README.md) · [Thread](../Docs/Thread/README.md) · [Seam](../Docs/Seam/README.md)

This folder defines everything an app puts into the index, and the file that lists which apps have a
lane. Each schema is shown in proto first. The dropdown under it shows the same schema in Swift, which
is what an app on AII writes.

| File | Package | Defines | Swift |
| --- | --- | --- | --- |
| [`record.proto`](record.proto) | `aii.v1` | `aii-record/1`, the envelope every document is filed in | `AIIRecord`, written by hand |
| [`lanes.proto`](lanes.proto) | `aii.v1` | `aii-lanes/1`, the lanes manifest at `~/.rao/aii/lanes.json` | `AIILanes`, written by hand |
| [`thread.proto`](thread.proto) | `thread.v1` | Thread's gRPC services: index, search, remove, library, documents, export, graph, and the session Sewn holds | generated, public: `Thread_V1_*` in `Sources/Seam/Generated` |
| [`fleet.proto`](fleet.proto) | `fleet.v1` | Fleet's LoRA slots | generated, public: `Fleet_V1_*` in `Sources/Seam/Generated` |

`AIIRecord` and `AIILanes` are the API, so apps never see a second, generated envelope type.
`record.proto` and `lanes.proto` are still compiled, into `Tests/AIITests/Generated` with internal
visibility, for the conformance tests (`Tests/AIITests/AIIRecordProtoTests.swift`). Those tests hold
each Swift form and its proto to each other in both directions:
- What AII writes parses as the message's proto3 JSON, with unknown fields refused.
- What a proto3 JSON printer writes reads back into AII as the same values.

## The record

A document's metadata in Thread is the proto3 JSON form of `aii.v1.Record`. The text and the graph are
not in it. They are filed beside it, as the document's partitions and entities (see
[Filing a record](#filing-a-record)).

```proto
syntax = "proto3";
package aii.v1;

import "google/protobuf/struct.proto";
import "google/protobuf/timestamp.proto";

message Record {
  string format = 1;                            // "aii-record/1"
  string app = 2;                               // the lane's app
  string id = 3;                                // the app's id for it, stable and unique within its kind
  string kind = 4;                              // open vocabulary: note, reading, image…
  string title = 5;
  Group group = 6;
  Source source = 7;
  repeated string tags = 8;                     // filed as concept entities, named as written
  optional string supersedes = 9;               // the id of the record of the same kind it replaces
  string media_type = 10;                       // "text", "code" or "image"
  google.protobuf.Timestamp remembered_at = 11;
  google.protobuf.Value payload = 12;           // the app's own value
  Image image = 13;                             // a visual record's picture
  Verified verified = 14;                       // a Rao Verified stamp
}

message Group {
  string id = 1;                                // on the wire, <app>-<id>
  string label = 2;
}

message Source {
  string kind = 1;                              // "app", "user", "import", "sewn-summary"…
  optional string ref = 2;                      // a path, a URL, a session id
}
```

<details>
<summary>Swift</summary>

```swift
// Sources/AII/Core/Contract/AIIRecord.swift
public struct AIIRecord: Codable, Sendable, Equatable {
    public var format: String                   // "aii-record/1"
    public var app: AIIApp
    public var id: String
    public var kind: Kind                       // .note, .image, "recipe"…
    public var title: String
    public var group: Group
    public var source: Source
    public var tags: [String]
    public var supersedes: String?
    public var mediaType: MediaType             // .text, .code, .image
    public var rememberedAt: Date               // to the second
    public var payload: AIIJSONValue?           // your value, as its own JSON
    public var image: Image?
    public var verified: Verified?

    public struct Group: Codable, Hashable, Sendable {
        public var id: String
        public var label: String
    }

    public struct Source: Codable, Hashable, Sendable {
        public var kind: String
        public var ref: String?
    }

    public var documentID: String               // <app>/<kind>/<id>
    public func canonicalJSON() throws -> Data
    public static func decode(_ metadata: Data) -> AIIRecord?
}
```

</details>

**Names.**

| Name | Rule | Example |
| --- | --- | --- |
| app | 2 to 32 of `a-z` and `0-9`, starting with a letter; never `aii` | `notes` |
| id | 1 to 128 of `A-Z a-z 0-9 . _ : @ -`, never `/` | `standup-1015` |
| kind | 1 to 32 of `a-z 0-9 -`, starting with a letter | `note` |
| group id | 1 to 64 of `a-z 0-9 . _ -` | `standups` |
| document id on the wire | `<app>/<kind>/<id>` | `notes/note/standup-1015` |
| group id on the wire | `<app>-<group id>` | `notes-standups` |

An app name holds no `-`, so a wire group always splits at its first `-`.

**The JSON.** The metadata has the same values as the message's proto3 JSON form.
- **How AII writes it:** keys sorted, `/` unescaped, and timestamps to the whole second in UTC
  (`2026-10-16T09:12:00Z`), so the same record is always the same bytes.
- **What AII reads:**
  - fields left out, as empty;
  - proto field names (`media_type`) as well as JSON names (`mediaType`);
  - fractional seconds and offsets, rounded down to the second;
  - a kind or media type it has no constant for, kept as written.

  It ignores fields it doesn't know.
- **Payload numbers** stay within ±2^53, so every JSON reader reads them exactly. A whole number reads
  back as an integer.
- **Size:** keep the envelope small, because it rides on every recall hit that asks for it. Bulk text
  belongs in the partitions, not the payload. AII refuses an envelope over 1 MB, a backstop for a state
  document that grows, such as Craft's ledger.

**Groups.** A wire group belongs to the first owner and the first lane that file into it. Filing into
another's is refused. Every app's groups start with its own name, so apps never collide, even under one
shared owner.

## Filing a record

A record goes to Thread as one `ThreadIndexItem`, inside a `ThreadIndexRequest` for its group.

```proto
// thread.proto
message ThreadIndexRequest {
  string owner_id = 1;
  string group_id = 2;
  string group_label = 3;
  string scope = 4;
  repeated ThreadIndexItem items = 5;
  string lane = 6;                              // ignored on a direct call: the secret names the lane
}

message ThreadIndexItem {
  string document_id = 1;
  repeated string texts = 2;                    // one partition each, in order
  repeated string tags = 3;                     // legacy
  string name = 4;
  bytes metadata = 5;                           // the envelope's canonical JSON
  string media_type = 6;
  repeated ThreadGraphEntityIn entities = 7;
  repeated ThreadGraphRelationIn relationships = 8;
  repeated ThreadPartitionInput partitions = 9; // parallel to texts, when the filer describes them
}

message ThreadPartitionInput {
  repeated float embedding = 1;                 // precomputed; empty means Thread embeds texts[i]
  string url = 2;                               // the partition's own address; "" means the document's
}

message ThreadGraphEntityIn {
  string name = 1;
  string kind = 2;                              // person|organization|place|event|work|concept|other
}

message ThreadGraphRelationIn {
  string subject = 1;
  string predicate = 2;
  string object = 3;
}
```

<details>
<summary>Swift</summary>

```swift
// Sources/AII/Join/AIIRecordable.swift: what an app's own type adopts.
public protocol AIIRecordable: Codable, Sendable {
    static var kind: AIIRecord.Kind { get }
    static var group: AIIRecord.Group { get }
    var recordID: String { get }
    var title: String { get }
    var text: String { get }                              // what is embedded and searched

    // Each has a default.
    var group: AIIRecord.Group { get }                    // Self.group
    var tags: [String] { get }                            // none
    var entities: [AIIRecord.Entity] { get }              // none: Thread extracts
    var relationships: [AIIRecord.Relationship] { get }   // none
    var source: AIIRecord.Source { get }                  // app
    var supersedes: String? { get }                       // none
    var mediaType: AIIRecord.MediaType { get }            // .text
    var partitions: [AIIDocument.Partition] { get }       // text, split into ~1,500 characters
    var image: AIIRecord.Image? { get }                   // none
    var verified: AIIRecord.Verified? { get }             // none
}

extension AIIRecordable {
    public func envelope(app: AIIApp, now: Date = Date()) throws -> AIIRecord
    public func document(app: AIIApp, now: Date = Date()) throws -> AIIDocument
}

// Sources/AII/Core/Contract/AIIDocument.swift: a record as Thread files it.
public struct AIIDocument: Sendable, Equatable {
    public struct Partition: Sendable, Equatable {
        public var text: String
        public var url: String?
        public var embedding: [Float]?
        public var region: AIIRecord.Region?
    }

    public var record: AIIRecord
    public var partitions: [Partition]
    public var entities: [AIIRecord.Entity]
    public var relationships: [AIIRecord.Relationship]

    public var documentID: String                         // <app>/<kind>/<id>
    public var wireGroupID: String                        // <app>-<group>
    public var graphEntities: [AIIRecord.Entity]          // entities, then each tag as a concept
    public func validate() throws
}

// Sources/AII/Join/AIIDocument+Thread.swift
extension AIIDocument {
    public func indexItem() throws -> Thread_V1_ThreadIndexItem
    public static func indexRequests(_ documents: [AIIDocument], owner: AIIOwner,
                                     maximumBytes: Int = 16 * 1024 * 1024) throws -> [Thread_V1_ThreadIndexRequest]
}
```

</details>

| Wire field | Comes from |
| --- | --- |
| `ThreadIndexRequest.owner_id` | the owner the app files under ([Owners](#owners)) |
| `group_id`, `group_label` | `<app>-<record.group.id>`, `record.group.label` |
| `scope` | `personal` |
| `ThreadIndexItem.document_id` | `<app>/<kind>/<id>` |
| `name` | `record.title` |
| `texts` | each partition's text: `text` split on paragraph and sentence boundaries, or the type's own `partitions` |
| `partitions` | each partition's url and vector; sent only when a partition has one |
| `metadata` | the record's canonical JSON |
| `media_type` | `record.media_type` |
| `entities` | the type's entities, then each tag as a `concept`, once per name as Thread compares names |
| `relationships` | the type's relationships |
| `tags` | unused: tags travel as entities |

`indexRequests` makes one request per group and starts a new one before a request passes 16 MB. The
wire takes 32 MB, and one picture with its tile vectors is about 5 MB. Any entity, a tag included,
turns Thread's own extraction off for that document. Re-filing an id replaces its partitions, its
metadata and its graph links. Filings of one id apply in the order Thread answered them.

## Visual records

A picture is a record of media type `image` that carries the picture in its envelope. Its regions are
partitions. Each region partition has its own vector, and its url ends in the
[W3C media fragment](https://www.w3.org/TR/media-frags/) `#xywh=pixel:x,y,w,h`.

```proto
// record.proto
message Image {
  string sha256 = 1;                            // of its bytes, or of the app's canonical pixels
  uint32 width = 2;                             // in pixels
  uint32 height = 3;
  optional string mime_type = 4;                // "image/png"
  optional string location = 5;                 // a file URL, or the app's own URL
  google.protobuf.Timestamp captured_at = 6;
}

// thread.proto: a region is one of the document's partitions.
message ThreadPartitionInput {
  repeated float embedding = 1;                 // the region's vector, from the index's embedder
  string url = 2;                               // <location, or aii:<document id>>#xywh=pixel:x,y,w,h
}
```

<details>
<summary>Swift</summary>

```swift
// Sources/AII/Join/AIIVisualRecordable.swift
public protocol AIIVisualRecordable: AIIRecordable {
    var picture: AIIRecord.Image { get }
    var caption: String { get }                           // the first partition, searched by text
    var captionEmbedding: [Float]? { get }                // default nil: Thread embeds the caption
    var regions: [AIIRecord.Region] { get }               // default none: one partition each
    var labels: [String] { get }                          // default none: the record's tags
}
// Defaults it sets: text = caption, mediaType = .image, tags = labels, image = picture,
// partitions = [caption] + regions, each region's url filled in by document(app:now:).

// Sources/AII/Core/Contract/AIIRecord.swift
extension AIIRecord {
    public struct Image: Codable, Hashable, Sendable {
        public var sha256: String
        public var width: Int
        public var height: Int
        public var mimeType: String?
        public var location: String?
        public var capturedAt: Date?
    }

    public struct Region: Hashable, Sendable {
        public var x: Int, y: Int, width: Int, height: Int
        public var embedding: [Float]?
        public var text: String                           // usually "": found by its vector
        public var fragment: String                       // "xywh=pixel:x,y,w,h"
        public init?(fragment: String)
        public init?(url: String)
    }
}

// A picture, as Veil describes one. The caption and tiles are filed as partitions, so the
// payload keeps only the rest.
struct Photo: AIIVisualRecordable {
    static let kind: AIIRecord.Kind = .image
    static let group = AIIRecord.Group(id: "camera", label: "Camera roll")
    var recordID: String
    var title: String
    var picture: AIIRecord.Image
    var labels: [String]
    var caption = ""
    var tiles: [AIIRecord.Region] = []
    var regions: [AIIRecord.Region] { tiles }
    enum CodingKeys: String, CodingKey { case recordID, title, picture, labels }
}
```

</details>

A region's vector must come from the index's own embedder (`AIIModels.embedding`, 1,024 dimensions).
Thread refuses a vector of another size. A recall hit on a region carries that region's url, and
`hit.region` reads the rectangle back.

## Provenance

```proto
// record.proto
message Verified {
  string record = 1;                            // the Rao Verified record, as its canonical JSON
  string seal = 2;                              // the seal over it, base64
}
```

<details>
<summary>Swift</summary>

```swift
extension AIIRecord {
    public struct Verified: Codable, Hashable, Sendable {
        public var record: String
        public var seal: String
    }
}
```

</details>

A Rao Verified stamp is the signed record of what a person read or made. The Mac's signing key
(`AIISigningKey`) makes the seal. The record names the document id and its owner, so a stamp can't
be moved to another document or person. A training export reads the stamp from the envelope.

## Owners

An owner is a person within a lane. Every request that reads or writes documents names one, and a
search, a remove or an export sees only the owner it names.

```proto
// thread.proto: the owner field of each request that reads or writes documents.
message ThreadIndexRequest        { string owner_id = 1; /* … */ }
message ThreadSearchRequest       { string owner_id = 3; /* … */ }
message ThreadRemoveRequest       { string owner_id = 1; /* … */ }
message ThreadRemoveGroupsRequest { string owner_id = 1; /* … */ }
message ThreadDocumentsRequest    { string owner_id = 1; /* … */ }
message ThreadLibraryRequest      { string owner_id = 1; /* … */ }
message ThreadExportCorpusRequest { string owner_id = 1; /* … */ }
message ThreadGraphQueryRequest   { string owner_id = 1; /* … */ }
```

<details>
<summary>Swift</summary>

```swift
// Sources/AII/Core/Contract/AIIOwner.swift
public struct AIIOwner: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public static let local: AIIOwner                     // "aii-local"
    public static func app(_ app: AIIApp) -> AIIOwner     // "local-<app>"
    public static func account(_ id: String) -> AIIOwner  // a signed-in person, lowercased

    public var isLocal: Bool                              // aii-local or local-<app>: no account
    public func isLaneOwner(for app: AIIApp) -> Bool      // aii-local, or the app's own
}
```

</details>

| Owner | On the wire | Who |
| --- | --- | --- |
| `AIIOwner.local` | `aii-local` | No account, shared by every app that opts in. Craft always files here. Ambient and Veil file here when nobody is signed in, Private mode included. |
| `AIIOwner.app(app)` | `local-<app>` | No account, the app's own. A new lane starts with it, except the Rao apps' lanes, which start under `aii-local`. |
| `AIIOwner.account(id)` | the account id, lowercased | A signed-in person. |

**Opting in to `aii-local`** puts an app's local records under the same owner as Craft's, Ambient's and
Veil's. Each app's records still sit in its own lane. It is a choice, and an app that makes none keeps
`local-<app>`. Opt in one of three ways:
- **With `AIIInstance`:** `AIIInstance(Notes.self, owner: .local)`. `join()` writes the owner to the lane's
  entry in the [lanes manifest](#the-lanes-manifest).
- **With your own client:** `AIISupervisor.prepare(owner: .local)`, then file and search with
  `ownerID = AIIOwner.local.rawValue`.
- **From a terminal:** `aii lanes owner notes aii-local`.

Sewn answers a call made without an account as the lane's owner in the manifest, so `ask` grounds in
the documents `recall` sees. Documents already filed keep their owner until they are filed again. Sewn's
memory groups carry the app's name too (`<app>-memory-<owner>`, `<app>-resonance-<owner>`), so two apps
under `aii-local` never share one.

A deposit and a search under `aii-local`, on the wire (`lane` is the client from
[Thread → Connect](../Docs/Thread/README.md#connect)):

```swift
import AII
import Seam

let note = AIIRecord(app: "notes", id: "standup-1015", kind: .note, title: "Stand-up",
                     group: .init(id: "standups", label: "Stand-ups"), tags: ["Joltvault"])
let document = AIIDocument(record: note, partitions: [.init(text: "Ada leads Joltvault. The demo is Thursday.")])

var deposit = Thread_V1_ThreadIndexRequest()
deposit.ownerID = AIIOwner.local.rawValue               // "aii-local"
deposit.groupID = document.wireGroupID                  // "notes-standups": the app's own group
deposit.groupLabel = note.group.label
deposit.scope = "personal"
deposit.items = [try document.indexItem()]
_ = try await lane.call { [deposit] in try await Thread_V1_ThreadQuery.Client(wrapping: $0).index(deposit) }
// AIIDocument.indexRequests([document], owner: .local) builds the same request.

var search = Thread_V1_ThreadSearchRequest()
search.ownerID = AIIOwner.local.rawValue
search.queryText = "who leads Joltvault?"
search.aggregate = true                                 // every group aii-local holds in this lane
search.topK = 8
search.includeMetadata = true
let found = try await lane.call { [search] in try await Thread_V1_ThreadQuery.Client(wrapping: $0).search(search) }
let records = found.results.compactMap { AIIRecord.decode($0.metadata) }
```

## The lanes manifest

`~/.rao/aii/lanes.json` lists every lane on this Mac. It is the proto3 JSON form of
`aii.v1.LaneManifest`.

```proto
// lanes.proto
message LaneManifest {
  string format = 1;                            // "aii-lanes/1"
  map<string, Lane> lanes = 2;                  // by app name
}

message Lane {
  string id = 1;                                // a lowercase uuid, derived once from the device key
  string derived_from = 2;                      // the device key's fingerprint
  google.protobuf.Timestamp registered_at = 3;
  string display_name = 4;                      // the first registration's
  optional string bundle_identifier = 5;
  string registered_by = 6;                     // the app's name, or "aii" for the stack
  string owner = 7;                             // "aii-local" or "local-<app>"
}
```

<details>
<summary>Swift</summary>

```swift
// Sources/AII/Core/Keys/AIILane.swift
public struct AIILanes: Sendable, Equatable {
    public static let format = "aii-lanes/1"

    public struct Lane: Codable, Sendable, Equatable {
        public var id: LaneID
        public var derivedFrom: String
        public var registeredAt: Date
        public var displayName: String
        public var bundleIdentifier: String?
        public var registeredBy: StackIdentity
        public var owner: AIIOwner
    }

    public var lanes: [AIIApp: Lane]
    public func lane(for app: AIIApp) -> Lane?
    public func owner(for app: AIIApp) -> AIIOwner
    public static func load(home: AIIHome) throws -> AIILanes?
}

// Sources/AII/Core/Contract/AIIHome+Registration.swift
extension AIIHome {
    public func register(_ app: AIIApp, displayName: String? = nil, bundleIdentifier: String? = nil,
                         owner: AIIOwner? = nil, by registrant: StackIdentity? = nil) throws -> AIILanes.Lane
    public func lane(_ app: AIIApp) -> AIILanes.Lane?
    public func setOwner(_ owner: AIIOwner, for app: AIIApp) throws
    public func unregister(_ app: AIIApp) throws
}
```

</details>

```json
{
  "format" : "aii-lanes/1",
  "lanes" : {
    "notes" : {
      "bundleIdentifier" : "com.example.notes",
      "derivedFrom" : "3127cb94",
      "displayName" : "Notes",
      "id" : "8a8d210f-a989-ffd4-3b44-d1f41a2d7298",
      "owner" : "local-notes",
      "registeredAt" : "2026-10-16T09:12:00Z",
      "registeredBy" : "notes"
    }
  }
}
```

A registration is two files: `secrets/<app>`, and the app's entry in the manifest.
- **Who writes the entry:** `AIIInstance.join()`, `AIISupervisor.prepare()` and `aii lanes add` add it.
  It is written under `aii/.lanes.lock`.
- **First registration wins:** the first registration's id and display name stay.
- **Owner changes:** an explicit owner updates the entry. A running server reads the change within
  two seconds, without a restart.
- **Start fresh:** a file in another format reads as absent and is rebuilt from `secrets/`, with the
  same ids from the same device key.

`aii lanes` lists the manifest and manages it. `aii lanes doctor <name>` walks one lane down the stack
and names the layer to fix.

Today the servers admit any app whose secret is in `secrets/`. The manifest is laid out so a later
change can make a node admit only the lanes it lists.

## Recalling a record

```proto
// thread.proto
message ThreadSearchRequest {
  string owner_id = 3;
  int32 top_k = 5;
  repeated string group_ids = 6;                // <app>-<group>; or aggregate = true for all the owner holds
  bool aggregate = 7;
  string query_text = 8;
  bool include_metadata = 12;                   // fill each result's name, group_id, metadata and url
  // …
}

message ThreadPartitionResult {
  string partition_id = 2;
  string document_id = 3;
  string owner_id = 4;
  string text = 5;
  float score = 6;                              // a distance: lower is closer
  string name = 8;
  string group_id = 9;
  bytes metadata = 10;                          // the envelope, byte for byte
  string url = 11;                              // the partition's own url, such as a region of a picture
  // …
}
```

<details>
<summary>Swift</summary>

```swift
// Sources/AII/Join/AIIRecall.swift
public struct AIIRecall: Sendable {
    public struct Hit: Sendable, Identifiable {
        public let documentID: String
        public let partitionID: String
        public let text: String
        public let distance: Float
        public let name: String?
        public let groupID: String?
        public let record: AIIRecord?                     // nil for a document filed by hand
        public let url: String?
        public var region: AIIRecord.Region? { get }
    }

    public struct Match<Value: AIIRecordable>: Sendable {
        public let value: Value
        public let hit: Hit
    }

    public let hits: [Hit]
    public let trace: Trace
}

// Sources/AII/Join/AIIInstance+Thread.swift
extension AIIInstance {
    public func recall<T: AIIRecordable>(_ query: String, as type: T.Type, in groups: [String]? = nil,
                                         topK: Int = 8) async throws -> [AIIRecall.Match<T>]
    public func recall(_ query: String, in groups: [String]? = nil, kinds: [AIIRecord.Kind]? = nil,
                       topK: Int = 8) async throws -> AIIRecall
}
```

</details>

`recall(_:as:)` keeps the hits of the type's kind and decodes each payload back into the type. Thread
filters by owner, group and media type only, so the kind filter runs in AII, over a wider search.

## Kinds in use

| Filer | Kinds | Document ids | Groups on the wire |
| --- | --- | --- | --- |
| Ambient | `reading`, `manifest`, `turn`, `insight`, `note` | `ambient/reading/<16 hex>`, `ambient/manifest/<16 hex>`, `ambient/turn/<uuid>`, `ambient/insight/<uuid>`, `ambient/note/<16 hex>` | `ambient-reading-<owner>`, `ambient-interaction-<owner>`, `ambient-seer-<owner>` |
| Craft | `convention`, `approach`, `note`, `ledger`, `instructions`, `settings`, `code` | `craft/<kind>/<project>.<record>.<version>` for a record, `<project>.<version>` for a ledger, instructions or settings, `<scope>.<path>.<hash>` for code: each version is its own id | `craft-conventions`, `craft-records`, `craft-memory`, `craft-code-<scope>` |
| Veil | `image` | `veil/image/img-<32 hex>` | `veil-<12 hex>`, one per picture set |
| Sewn | `memory` | `<app>/memory/<id>` | `<app>-memory-<owner>`, `<app>-resonance-<owner>` |
| Notes | `note` | `notes/note/<id>` | `notes-notes` |

The vocabulary is open: a new kind needs no change here, only a name that follows the rule.

## Regenerating

```sh
Scripts/generate-seam.sh                           # protoc, with plugins built from this package's checkouts
swift test --filter AIITests.AIIRecordProtoTests   # the Swift forms against record.proto and lanes.proto
```

The script compiles `thread.proto` and `fleet.proto` into `Sources/Seam/Generated` (public), and
`record.proto` and `lanes.proto` into `Tests/AIITests/Generated` (internal). It needs `protoc`
(`brew install protobuf`). It builds `protoc-gen-swift` and `protoc-gen-grpc-swift` from the resolved
`swift-protobuf` and `grpc-swift-protobuf` checkouts, so the generated code matches the runtime the
package links. A change to `record.proto` or `lanes.proto` is a change to `AIIRecord` or `AIILanes`.
Make both, then run the conformance tests.
