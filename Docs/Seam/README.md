# Seam — the wire

[← the stack](../../README.md) · [AII](../AII/README.md) · [Thread](../Thread/README.md) · [Sewn](../Sewn/README.md)

Seam is the gRPC contract every piece of the index speaks. It holds the canonical `.proto` files
(`Protos/`), the Swift generated from them (`Sources/Seam/Generated/`), and the session, client, server
and security machinery around them. Sewn, Thread and every app compile against the same types from the
same source. Change the contract in one place and regenerate, and every consumer either builds against
the new shape or fails loudly.

Seam is a library only. An app takes it as `.product(name: "Seam", package: "AII")` with
`traits: []`. It links grpc-swift 2, the NIO HTTP/2 transport, grpc-swift-protobuf, swift-protobuf and
swift-log, and nothing behind the `Server` trait.

![Seam's two call paths. Apps call Thread directly: a unary RPC on gRPC 47090 whose secret picks the lane. Thread dials Sewn on 47091: Register, then a heartbeat every 15 seconds on its own connection, and a Session stream it holds open. Sewn pushes requests down that stream as ThreadSessionMessage envelopes carrying a correlation id and the caller's lane. A legend explains the six regions and the marks: what dials, what is held open, what is pushed down, the liveness timings, the per-RPC timeouts and the secret.](../README_Assets/seam-wire.png)

## Two call paths

**The direct path.** A caller on the same Mac calls Thread's `ThreadQuery`, `ThreadLibrary`,
`ThreadGraph` and `ThreadUpdate` as ordinary unary RPCs on Thread's port. There is no envelope and no
correlation. This is how every app reads and writes its lane.

**The session path.** A mothership cannot dial a node: a laptop, a Pi or a box behind NAT has no
reachable address. So the node dials in, registers, and holds a bidirectional `Session` stream open.
The mothership wraps each request in a `ThreadSessionMessage`, stamps it with a `correlation_id`, and
writes it down the stream. The node dispatches it and writes the correlated response back up. One
stream carries many requests in flight. On a Mac this is how Sewn reaches Thread for every chat turn.

| | Role | Takes from Seam |
| --- | --- | --- |
| **Apps** | callers | the generated `Thread_V1_*` clients; `StackSecretClientInterceptor` with the app's secret |
| **Thread** | node | `MothershipRegistrationClient`, both interceptors; implements `SessionRequestHandling`; hosts the generated services |
| **Sewn** | mothership | `ThreadRegistrationServiceImpl`, `ThreadSessionManager`, `ThreadQueryClient`, `StackSecretServerInterceptor`; implements `ThreadRegistry` |
| **Fleet** (outside this package) | LoRA training | hosts `FleetLoRA`; its desktop client runs `SeamMothershipServer` so Threads can dial it |

## Integrate

### Call Thread from an app

```swift
import AII
import Seam
import GRPCCore
import GRPCNIOTransportHTTP2

let home = AIIHome.resolved()
let transport = try HTTP2ClientTransport.Posix.http2NIOPosix(
    target: .ipv4(host: "127.0.0.1", port: AIIConfig.load(home: home).threadPorts.grpc),
    transportSecurity: .plaintext)
let secret = StackSecretClientInterceptor(secret: { try? home.readSecret(for: "notes") })   // read per RPC

let stats = try await withGRPCClient(transport: transport, interceptors: [secret]) { client in
    try await Thread_V1_ThreadUpdate.Client(wrapping: client).stats(Thread_V1_ThreadStatsRequest())
}
print(stats.documentCount, stats.groupCount)
```

The generated clients are nested types: `Thread_V1_ThreadQuery.Client`, `Thread_V1_ThreadLibrary.Client`,
`Thread_V1_ThreadGraph.Client` and `Thread_V1_ThreadUpdate.Client`, each made with
`init(wrapping: GRPCClient)`. Depositing, searching and walking the graph are in
[Thread → Integrate](../Thread/README.md#integrate).

The interceptor stamps `x-ambient-secret` on every RPC. Pass `secret:` as a closure (read per call, nil
adds nothing) or a fixed string. Attach it only to a loopback target, as Ambient, Craft and Veil do with
`StackSecret.isLoopback(host:)`. The server refuses non-loopback peers with `PERMISSION_DENIED` and
unknown secrets with `UNAUTHENTICATED`.

### Host a mothership

`SeamMothershipServer` and `InMemoryThreadRegistry` let anything become a destination that Threads
dial, with the HTTP/2 tuning large payloads need: a 100 MB message cap, a 16 MB window, 1 MB frames,
gzip, and keepalive.

```swift
import Seam
import Logging

let logger = SwiftLogSeamLogger(Logger(label: "my-mothership"))
let registry = InMemoryThreadRegistry()
let sessions = ThreadSessionManager(logger: logger)
let server = SeamMothershipServer(registry: registry, mothershipId: UUID(), sessionManager: sessions, logger: logger)
await server.start(port: 47191)
let threads = ThreadQueryClient(sessionManager: sessions)

for await nodes in await registry.changes() {          // every registration, heartbeat and drop
    guard let node = nodes.first(where: \.isActive) else { continue }
    var search = Thread_V1_ThreadSearchRequest()
    search.queryText = "who leads Joltvault?"
    search.ownerID = "local-notes"
    search.topK = 5
    let found = try await threads.search(search, thread: node)   // down the session, 30 s timeout
    print(found.results.map(\.documentID))
}
```

A Thread joins with `AIIServer thread … --mothership-host 127.0.0.1 --mothership-grpc-port 47191`. For
a secret on the wire, pass `interceptors: StackSecretServerInterceptor.forLocalMode(resolver:logger:)`
and a `callerResolver`. With a nil resolver the list is empty, so an open server changes nothing.

### Run a node

A node implements one method and hands it to `MothershipRegistrationClient`. That client registers
(waiting for the mothership if it is not up yet), opens the session, keeps it alive, and reconnects
on its own:

```swift
struct Dispatcher: SessionRequestHandling {
    func handle(_ message: Thread_V1_ThreadSessionMessage) async -> Thread_V1_ThreadSessionMessage? {
        guard case .searchRequest(let request)? = message.payload else { return nil }   // nil: unsupported
        var reply = Thread_V1_ThreadSessionMessage()
        reply.correlationID = message.correlationID
        reply.searchResponse = await answer(request)
        return reply
    }
}

let node = MothershipRegistrationClient(
    mothershipHost: "127.0.0.1", mothershipGRPCPort: 47191,
    threadId: UUID(), threadHost: "127.0.0.1", threadGRPCPort: 47090, threadHTTPPort: 47081,
    requestDispatcher: Dispatcher(), logger: logger)
await node.startHeartbeatLoop()
```

Thread's own dispatcher, `MothershipRequestDispatcher`, answers every arm against the index.

## Liveness and timeouts

- **Session liveness.** The node pings inside the session every 30 s. It also sends a unary
  `Heartbeat` every 15 s on its own short-lived connection, so a 100 MB push saturating the stream can
  never get a node evicted mid-transfer.
- **Watchdog and activity.** The node's 45 s watchdog tears down a silent session, and the loop
  reconnects after 5 s. A node counts as active while it was last seen under 60 s ago.
- **Per-RPC timeouts on the session.** Interactive reads time out at 30 s, library pages at 90 s and
  indexing at 120 s. Otherwise a wedged node would stall every fan-out, which means every chat turn.
- **On the shared stack, Thread registers as the stack identity** (`secrets/aii`). Sewn's interceptor
  resolves that to `aii` and refuses anything else, and anything not from loopback.

## The protos

The wire is two of the four files in `Protos/`. The other two define what apps put on it: the record
every document is filed in and the lanes manifest. [Protos](../../Protos/README.md) shows each schema
in proto with its Swift form.

### `Protos/thread.proto` — `package thread.v1`

| Service | Hosted by | Methods | Reachable by |
| --- | --- | --- | --- |
| `ThreadRegistration` | mothership | `Register`, `Heartbeat`, `UpdateAvailability`, `Session` | direct (it is the way in) |
| `ThreadQuery` | Thread | `Search`, `Index`, `Remove` | both paths |
| `ThreadLibrary` | Thread | `Library`, `Documents`, `ExportCorpus` | both, except `ExportCorpus`: direct only |
| `ThreadGraph` | Thread | `Query` | both paths |
| `ThreadUpdate` | Thread | `UpdateGroup`, `UpdateDocument`, `Stats`, `RemoveGroups` | both, except `RemoveGroups`: direct only |

`ThreadSessionMessage` is the session's envelope. It has a `correlation_id`, a `thread_id` (set on
every ping so the mothership knows the stream), and a `payload` `oneof` over ping, pong and every
request and response. Each request carries a `lane`. On the session, Thread trusts the lane Sewn
stamped after admitting the app's secret. On the direct path, the field is ignored and the lane comes
from the caller's own secret.

**When you add an RPC, add its request and response as messages *and* as new `oneof` arms of
`ThreadSessionMessage`.** Otherwise it works on the direct path and silently cannot be fanned out.
Fields 13–22 are reserved: they were the retired `ThreadHNSW` arms.

The one deliberate exception is `RemoveGroups`. It deletes groups, so it stays on the caller's own
authenticated connection: it has no arm, Sewn cannot carry it, and Thread refuses it from a trusted
(session) caller. Its request has no `lane` field; the caller's secret decides.

### `Protos/fleet.proto` — `package fleet.v1`

`FleetLoRA` is hosted by Fleet and dialled directly, with no session envelope. It has named LoRA slots,
one per `thread_id` and `ability_id`. Its methods are `ListAdapters`, `AdapterStatus`, `Train` (which
streams `TrainProgress`) and `Complete`, one completion gated through a ready slot. Nothing in this
package calls it.

### Regenerating

`Sources/Seam/Generated/` holds `thread.pb.swift`, `thread.grpc.swift`, `fleet.pb.swift` and
`fleet.grpc.swift`. Never edit them by hand. After editing a proto, run
[`Scripts/generate-seam.sh`](../../Scripts/generate-seam.sh). It builds `protoc-gen-swift` and
`protoc-gen-grpc-swift` from the package's resolved `swift-protobuf` and `grpc-swift-protobuf`, so the
generated code matches the runtime that is linked, and it emits public types. It needs `protoc`
(`brew install protobuf`).

The same script compiles `record.proto` and `lanes.proto`, the record and the lanes manifest, into
`Tests/AIITests/Generated` with internal visibility. They are not part of Seam: an app uses their Swift
forms, `AIIRecord` and `AIILanes`, and the conformance tests hold the two together. See
[Protos](../../Protos/README.md).

## Sources

| Folder | Holds |
| --- | --- |
| `Client/` | `MothershipRegistrationClient` (the node's side), `ThreadQueryClient` (the mothership's typed fan-out) |
| `Server/` | `SeamMothershipServer`, `ThreadRegistrationServiceImpl`, `InMemoryThreadRegistry` |
| `Session/` | `ThreadSessionManager`: one outgoing channel per node, `correlation_id → continuation`, timeouts; `ThreadSessionError` (`noSession`, `sessionAlreadyOpen`, `unexpectedPayload`, `timeout`) |
| `Security/` | `StackSecretServerInterceptor`, `StackSecretClientInterceptor`, `StackSecretMetadata` (the key, the loopback test, `callerApp(in:resolver:)`) |
| `Node/` | `ThreadNode`: id, host, ports, `lastSeen`, `acceptingStorage`, `isActive`, app |
| `Protocols/` | `ThreadRegistry` (the mothership implements it), `SessionRequestHandling` (the node), `SeamLogger` (both; `SwiftLogSeamLogger` adapts swift-log) |
| `Support/` | `payloadName(_:)`, a readable name for a payload in logs |

`swift test --filter SeamTests` runs the interceptors (alone and over the in-process transport), the
session manager and the registration flow.
