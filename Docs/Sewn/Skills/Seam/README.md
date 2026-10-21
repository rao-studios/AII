# Seam — The gRPC Session Layer

Seam is the library of the AII package that owns the wire between Sewn and
Thread. Sewn and Thread take it as a target dependency (`"Seam"` in the root
`Package.swift`); apps take it as `.product(name: "Seam", package: "AII")`. A
change to the wire is a change to this one package: regenerate, then fix both
servers in the same commit.

This skill covers the transport. For how Sewn *uses* it, see
`Skills/Thread/README.md`. The wire itself is documented in
[`Docs/Seam/README.md`](../../../Seam/README.md).

---

## What Lives Where

```
Protos/
├── thread.proto                  — Thread services + session envelope
└── fleet.proto                   — Fleet (small-model training) services
Sources/Seam/
├── Generated/                    — thread.pb, thread.grpc, fleet.pb, fleet.grpc
├── Node/ThreadNode.swift         — the node record
├── Protocols/
│   ├── SeamLogger.swift
│   ├── SessionRequestHandling.swift
│   └── ThreadRegistry.swift      — the registry seam
├── Security/StackSecretInterceptors.swift — x-ambient-secret on every RPC, loopback only
├── Server/
│   ├── SeamMothershipServer.swift         — a ready-made mothership
│   ├── ThreadRegistrationServiceImpl.swift
│   └── InMemoryThreadRegistry.swift       — test/dev registry
├── Session/ThreadSessionManager.swift     — the bidi session actor
├── Client/
│   ├── ThreadQueryClient.swift
│   └── MothershipRegistrationClient.swift
└── Support/PayloadName.swift

Sources/Sewn/GRPC/
├── SewnGRPCServer.swift          — hosts the registration service
└── SewnSeamLogger.swift          — bridges SeamLogger → SewnLogger
```

Sewn brings its **own** server host rather than using
`SeamMothershipServer`, because it needs the HTTP/2 tuning below and its own
registry (`RegistryMutator`) rather than `InMemoryThreadRegistry`.

---

## SewnGRPCServer

`Sources/Sewn/GRPC/SewnGRPCServer.swift`

```swift
actor SewnGRPCServer {
    @discardableResult
    func start(registry: RegistryMutator,
               nodeId: UUID,
               host: String,
               grpcPort: Int,
               stack: StackMode,
               sessionManager: ThreadSessionManager,
               logger: SewnLogger) -> ThreadSessionManager
    func stop()
}
```

It constructs `ThreadRegistrationServiceImpl(registry:mothershipId:sessionManager:logger:callerResolver:)`
and serves it over `http2NIOPosix` on `<host>:<grpcPort>` — where the HTTP server
binds (`--host`): loopback for a Sewn an app launched for itself, `0.0.0.0` only
where a deployment asks for it — **plaintext** (TLS is expected to terminate upstream).

### The HTTP/2 tuning — and why it exists

```swift
$0.rpc.maxRequestPayloadSize = 100 * 1024 * 1024   // 100 MB
$0.http2.targetWindowSize    = 16 * 1024 * 1024    // 16 MB
$0.http2.maxFrameSize        = 1 << 20             // 1 MB
$0.compression.enabledAlgorithms = [.gzip, .none]
$0.connection.keepalive.time    = .seconds(15)
$0.connection.keepalive.timeout = .seconds(10)
$0.connection.keepalive.clientBehavior.allowWithoutCalls = true
$0.connection.keepalive.clientBehavior.minPingIntervalWithoutCalls = .seconds(10)
```

The source comments record the incident behind each line, and they are worth
keeping:

> The big payloads (index/search/library responses, up to the cap above) arrive
> client→server on the bidi session stream — and the server's **default receive
> window is 64 KiB**, capping throughput at ~window/RTT. That default was the
> congestion-like throttling on every large push. Open the window, fatten
> frames, accept gzip from nodes (payloads are text-heavy).

> Detect dead Thread connections from this side too (mirrors
> `SeamMothershipServer`; previously the wired server had **no keepalive** and
> relied entirely on the node's client-side pings + 45 s watchdog).

Two lessons generalize: on a bidirectional stream the **flow-control window**,
not the payload cap, is what limits throughput; and a server with no keepalive
cannot tell a dead peer from an idle one.

---

## ThreadSessionManager

`Sources/Seam/Session/ThreadSessionManager.swift` — a `public actor`.

```swift
public func openSession(for threadId: UUID) throws -> (handle: SessionHandle, outgoing: AsyncStream<Thread_V1_ThreadSessionMessage>)
public func closeSession(_ handle: SessionHandle)
public func send(_ message: Thread_V1_ThreadSessionMessage, to threadId: UUID)
public func request(…)     // send + await the correlated reply
public func deliver(_ message: Thread_V1_ThreadSessionMessage)
```

The shape to understand:

- `openSession` returns the **outbound** stream the registration service hands to
  the node's `Session` RPC. While that stream lives, the node is reachable.
- `deliver` is called with every message arriving **from** the node. It matches
  replies to waiting `request` calls by correlation id.
- `request` is the request/response abstraction over a stream that has no such
  concept natively. Everything in `SewnCore+ThreadFanout.swift` ultimately rides it.
- `closeSession` finishes the stream, which is what makes the node stop
  receiving fan-out.

Sewn holds the manager for the process lifetime and hands it to both
`SewnGRPCServer` and `ThreadQueryClient`:

```swift
let sessionManager = ThreadSessionManager(logger: SewnSeamLogger(base: SewnLogger(logger)))
let grpcServer = SewnGRPCServer()
sewn._threadQueryClient = ThreadQueryClient(sessionManager: sessionManager)
await grpcServer.start(registry: …, nodeId: …, host: host, grpcPort: grpcPort,
                       stack: stack, sessionManager: sessionManager, logger: …)
```

One manager instance, shared. The client sends **through the session** rather
than dialing the node — which is the whole point of the inversion: Sewn never
needs a route back to a Thread node.

---

## ThreadQueryClient

`Sources/Seam/Client/ThreadQueryClient.swift`. One method per RPC, each taking the
target `ThreadNode`:

```swift
public func search(_ request: Thread_V1_ThreadSearchRequest, thread: ThreadNode) async throws -> Thread_V1_ThreadSearchResponse
public func index / remove / library / documents / graph
         / updateGroup / updateDocument / stats
```

Sewn stores it **type-erased** on the actor:

```swift
/// Type-erased ThreadQueryClient (cast to ThreadQueryClient where needed).
/// Stored as Sendable to keep the actor's stored properties isolation-clean.
nonisolated(unsafe) var _threadQueryClient: (any Sendable)?
```

Every `fanout*` begins by casting and bailing out when there is no client:

```swift
guard let client = _threadQueryClient as? ThreadQueryClient else { return ([], nil) }
```

`_threadQueryClient == nil` means **no Thread integration at all** — searches
return empty and removes log a warning. Nothing errors.

---

## ThreadRegistry — The Storage Seam

```swift
public protocol ThreadRegistry: Sendable {
    func registerNode(_ node: ThreadNode) async
    func heartbeatNode(threadId: UUID) async
    func updateNodeAvailability(threadId: UUID, accepting: Bool) async
}
```

Seam ships `InMemoryThreadRegistry` for tests and standalone use. Sewn
conforms its own actor instead:

```swift
extension RegistryMutator: ThreadRegistry {}
```

The conformance body is empty — `RegistryMutator`'s existing actor methods are
the witnesses. This is why node state and billing state share one actor.

---

## ThreadNode

```swift
public struct ThreadNode: Sendable {
    public let threadId: UUID
    public var host: String
    public let grpcPort: Int
    public let httpPort: Int
    public var lastSeen: Date
    public var acceptingStorage: Bool
    public let app: String?

    public var isActive: Bool { Date().timeIntervalSince(lastSeen) < 60 }
}
```

`isActive` is a **60-second** window on `lastSeen`, evaluated fresh on every
read. `host` is `var` so Sewn can rewrite it via `THREAD_HOST_OVERRIDE`;
`threadId`, `grpcPort`, `httpPort`, and `app` are `let`.

---

## SeamLogger

```swift
public protocol SeamLogger: Sendable {
    func debug / info / warning / error (_ label: String?, _ message: String)
}
```

Sewn's bridge:

```swift
/// Routes Seam's gRPC session/client logs through SewnLogger so the
/// structured Cockpit JSON lines (service label "Sewn") keep flowing.
struct SewnSeamLogger: SeamLogger {
    let base: SewnLogger
    func info(_ label: String?, _ message: String) { base.info(label, "\(message)", service: .sewn) }
    // …
}
```

Without this, Seam's session diagnostics would bypass the structured log
pipeline and never reach Cockpit. If session logs go missing, check that the
logger was threaded through — both `ThreadSessionManager` and
`SewnGRPCServer.start` take one.

---

## fleet.proto

Seam also carries `fleet.proto` and its generated bindings, for **Fleet** —
the MaryOS small-model training component (LoRA adapters, schema-gated decoding).
Sewn does not serve or call Fleet services today; the relationship is that Fleet
produces adapters the on-device provider can serve. Do not wire Fleet RPCs into
Sewn without a reason — the bindings exist because the wire is shared, not
because Sewn is a Fleet client.

---

## Changing the Protocol

Seam is **shared**: Sewn, Thread (both in this package) and Fleet (outside it)
build against it. A proto change is a fleet-wide change.

1. Edit `Protos/thread.proto`. **Add** fields and messages; never renumber or
   reuse a field number.
2. If the message travels on the session stream, add the request/response pair to
   the `ThreadSessionMessage` `oneof`.
3. Regenerate with `Scripts/generate-seam.sh` and commit the generated files —
   they are checked in, not built at compile time.
4. Add the `ThreadQueryClient` method.
5. Implement the RPC on Thread, and the `fanout*` wrapper in Sewn, in the same
   commit: one binary carries both, so they never run on different wires.
6. Fleet follows on its own schedule. A Sewn that sends a payload an older peer
   cannot decode gets a failed RPC, which search treats as a dead node — silently
   degraded recall rather than a visible error.

---

## Debugging the Transport

| Symptom | Where to look |
|---------|--------------|
| Node registers then goes quiet | `isActive` is a 60 s window — is `Heartbeat` arriving? |
| Node never appears | `GET /v1/threads`; then the gRPC port (`--grpc-port`, 9091 by default; 47091 on the AII stack) |
| Search returns nothing, no errors | `_threadQueryClient` is nil, or zero **active** nodes |
| Large index pushes crawl | Flow-control window, not payload cap. Check `targetWindowSize` |
| Stale connections linger | Keepalive settings in `SewnGRPCServer` |
| Node advertises an unroutable host | `THREAD_HOST_OVERRIDE` |
| No session logs in Cockpit | `SewnSeamLogger` not threaded into the manager or server |
