# AII — the library every app links

[← the stack](../../README.md) · [the `aii` command](CLI.md) · [Thread](../Thread/README.md) · [Sewn](../Sewn/README.md) · [Seam](../Seam/README.md)

`AII` is the part of this package an app compiles, in two layers. `Core/` is the foundation: the
`~/.rao` contract, the keys and lanes, the record schema, the pinned model list, and the launcher,
supervisor and client that install, run and watch the two servers. `Join/` is what an app inherits and
holds: a lane descriptor, a record protocol and one actor, `AIIInstance`. Both build on Seam and the gRPC
wire. Neither holds MLX or server code.

![Join the index in six steps. 1 Depend: the AII package by URL with traits: [], product AII. 2 Describe your lane: an AIIAppDescriptor with static let app: AIIApp = "notes"; join() writes secrets/notes, the lane and apps/notes/, and the running servers admit it at once. 3 Describe your record: struct Note: AIIRecordable, filed in an aii-record/1 envelope that carries your value back whole. 4 Join: AIIInstance(Notes.self), then join(), which registers the lane, installs a bundled helper, adopts or starts the stack and waits for proof. 5 Remember and recall on Thread, gRPC 47090, in your lane; Notes come back as Notes. 6 Ask Sewn on 47080, on device or with your key, grounded and cited; forget a group, or forgetMemory(). Above the steps, the flow: your app, AIIInstance, ~/.rao, Sewn and Thread, your lane.](../README_Assets/join-guide.png)

| Folder | Holds |
| --- | --- |
| `Core/Contract/` | `AIIHome` (the view of `~/.rao`, with provisioning and registration), `AIIApp`, `AIIOwner`, `AIIRecord`, `AIIDocument` and `AIIJSONValue` (`aii-record/1`), `AIIContract`, `AIIPortPlan`, `StackSecret`, `StackChallenge`, `StackIdentity`, `StackKeyring`, `StackMode`, `LaunchSpec`, `AIIFiles`, `ProviderKeyStore` |
| `Core/Keys/` | `AIIDeviceKey` (32 bytes, `keys/device.key`), `AIILanes` (the lanes manifest), `AIILaneRegistry` (the servers' live view of it), `AIISigningKey` (the Mac's P-256 signer) |
| `Core/Models/` | `AIIModels`: the only place a base model id and its commit are spelled |
| `Core/Launcher/` | `AIIInstaller`, `AIICheckout`, `AIIReset`, `AIILeases`, `ManagedServer`, `CodeSignature` (macOS) |
| `Core/Supervisor/` | `AIISupervisor`, `AIIStatus`, `ThreadEmbedderState` |
| `Core/Client/` | `AIIClient` (health, lane stats, models over HTTP), `AIIStats` |
| `Join/` | `AIIAppDescriptor`, `AIIRecordable`, `AIIVisualRecordable`, `AIIInstance` (join, remember, recall, forget, ask), `AIIRecall`, `AIIAnswer`, `AIIChunker`, a document's requests to Thread (`AIIDocument+Thread`), and `AIILaneInspector` (what a lane holds, for the lane doctor) |

## Join

An app joins with two declarations and one actor. This section is all of
[`Examples/Notes`](../../Examples/Notes/Sources/Notes/main.swift), which builds in this repository the
way your app builds against it.

### Depend on AII, servers off

```swift
// swift-tools-version: 6.1 or later
dependencies: [
    .package(url: "https://github.com/rao-studios/AII.git", branch: "main", traits: []),
],
targets: [
    .executableTarget(name: "Notes", dependencies: [.product(name: "AII", package: "AII")]),
]
```

`traits: []` turns off the `Server` trait. Swift 6.2+ then prunes every server-only package from your
graph (Frigate and its SinatraHarness, Hummingbird, Supabase, Web3, Prometheus, ArgumentParser). Your
app resolves AII and Seam, grpc-swift and its NIO transport, swift-protobuf,
swift-log, swift-crypto and their own dependencies, and nothing else.
`swift build --disable-default-traits --product AII` shows the same view from this checkout. Never
depend on AII by path in a shipped app.

### Describe the lane and the record

```swift
import AII

/// The lane: Notes' name in the index. The first app to register a name on a Mac owns it.
enum Notes: AIIAppDescriptor {
    static let app: AIIApp = "notes"
    static let displayName = "Notes"
}

/// The schema of what Notes pushes into its lane. Its fields are its own.
struct Note: AIIRecordable {
    static let kind: AIIRecord.Kind = "note"
    static let group = AIIRecord.Group(id: "notes", label: "Notes")

    var recordID: String
    var title: String
    var body: String
    var tags: [String] = []

    var text: String { body }        // what is embedded and searched
}
```

- **The lane is a name:** 2 to 32 of `a-z` and `0-9`, starting with a letter, and never `aii`. It has no
  `-`, so a wire group `<app>-<group>` always splits at its first `-`. A literal that breaks the rule
  traps, because it is your own constant. `AIIApp(rawValue:)` and `AIIApp.named(_:)` check a name at
  run time. `bundleIdentifier` defaults to the main bundle's.
- **The record is your own type.** `AIIRecordable` asks for a `kind`, a `group`, a `recordID`, a
  `title` and the `text` to search, and has defaults for the rest. See [The record](#the-record).

### Join, remember, recall, ask, forget

```swift
let aii = AIIInstance(Notes.self)
try await aii.join()                                      // register, install, adopt or start, prove

try await aii.remember(notes)                             // filed, and searchable when it returns
for match in try await aii.recall("Who leads Joltvault?", as: Note.self, topK: 2) {
    print(match.value.title, match.hit.distance)          // Notes come back as Notes
}

for try await event in aii.ask("Who leads Joltvault, and when is the demo?") {
    switch event {
    case .references(let cited): show(cited.map(\.id))   // first: what the answer may cite
    case .token(let text): append(text)
    case .contribution, .finished: break
    }
}

try await aii.forget(groups: ["notes"])                   // the group and every record in it
await aii.leave()                                         // drop the lease; the last app out stops the stack
```

`join()` does four things, in order:
1. **Registers the lane** the first time: `secrets/notes`, and the app's entry in the lanes manifest,
   `aii/lanes.json`. The running servers admit the app on its first call, and nothing restarts. An
   index made with an owner writes it to the entry.
2. **Installs the helper** your bundle ships in `Contents/Helpers`, when it ships one and the rules let
   it (see [Who owns the install](#who-owns-the-install)). A development build ships none and runs
   what is installed.
3. **Adopts or starts** Sewn and Thread, and takes a lease.
4. **Waits for proof:** both servers must answer a challenge with your app's secret.

Run the example on a Mac where AII is installed (`aii install`, or any Rao app). It prints one line
per step: the lane registered, three notes filed, the closest two recalled as `Note`s, a cited
answer, and the group forgotten.

```sh
swift run --package-path Examples/Notes
```

Things to know:
- **No account is needed.** Records are filed under the lane's owner from the manifest: `local-notes`,
  Notes' own, unless the app opts in to the shared `aii-local` with `AIIInstance(Notes.self, owner: .local)`
  (see [Owners](#owners)). Sewn answers an app that has no account as that same owner, so `recall` and
  `ask` see the same documents. `ask` runs on device, or on Mistral or Tinker when the home holds that
  key (`aii setup`, `aii keys set mistral`); `AIIAnswer.Options(provider: .local)` pins it to the Mac.
- **Show one status.** `aii.status()` streams `AIIStatus`. Show it as "Ambient Intelligence Index"
  ("AII" where there is no room, with the full name a hover away). `aii.supervisor` and
  `aii.client` are there for anything lower.
- **At quit**, call `aii.shutdownSync()` from a terminate handler that can't await.
- **Errors.** `AIIInstanceError.notJoined` means a call came before `join()`. `.notReady` means the
  embedder is loading or a server is starting, so try again. `.refused` means Thread refused the call.

## The record

Every document an app files is wrapped in one envelope, `aii-record/1` (`AIIRecord`). The envelope
holds what every app shares. Your app's own meaning stays in your type, which rides along as the
payload. The schema is defined in proto as `aii.v1.Record`, in
[Protos → The record](../../Protos/README.md#the-record), and the metadata Thread keeps is that
message's JSON.

| Field | |
| --- | --- |
| `format` | `aii-record/1` |
| `app` | the lane's name |
| `id` | your `recordID`: 1 to 128 of `A-Z`, `a-z`, `0-9` and `. _ : @ -`, with no `/` |
| `kind` | your type's `kind`: 1 to 32 of `a-z`, `0-9` and `-`, starting with a letter. Named ones are `note`, `document`, `convention`, `approach`, `memory`, `event` and `image`. |
| `title` | your `title` |
| `group` | `{id, label}`: `Self.group`, unless the value says otherwise |
| `source` | `{kind, ref?}`: `app` by default |
| `tags` | words to match it by; none by default |
| `supersedes` | the id of the record of the same kind it replaces |
| `mediaType` | `text`, `code` or `image`; `text` by default |
| `rememberedAt` | when it was filed, to the second |
| `payload` | your value, as its own JSON |
| `image` | the picture, for a visual record |
| `verified` | a Rao Verified stamp, when the record carries one |

The text and the graph are not in the envelope. They are filed beside it (`AIIDocument`):
- **Partitions:** your `text`, split into pieces of about 1,500 characters on paragraph and sentence
  boundaries. Override `partitions` to keep your own chunks, or to give a partition its own url or a
  vector from the index's embedder.
- **The graph:** your `entities` and `relationships`, then each tag as a concept entity named exactly
  as written, so a query that names the word finds the record. With none of them, Thread extracts a
  graph on device.

Keep bulk text out of your type's encoded shape (leave it out of `CodingKeys`, or keep it beside the
type). The partitions carry it, and the envelope rides on every recall hit that asks for it. AII
refuses an envelope over 1 MB, a backstop for a state document such as Craft's ledger.

**How a record lands in Thread.** One record is one document:
- **Document id** `<app>/<kind>/<id>`, such as `notes/note/standup-1015`. A reference carries only the
  id, so provenance is readable from it, and two apps' ids never collide.
- **Group** `<app>-<group>`, such as `notes-notes`, because group ids share one key space. A group
  belongs to the first owner and lane that file into it.
- **Owner:** the index's owner (see [Owners](#owners)).
- **Name, texts and metadata:** the title, the partitions, and the envelope's canonical JSON. Its keys
  are sorted and its dates are ISO-8601 to the second, so the same record is always the same bytes.

**Pictures.** A type that adopts `AIIVisualRecordable` describes a picture: the `picture`
(`AIIRecord.Image`: its SHA-256, size, MIME type and location), a `caption` searched by text, its
`regions` (each searched by its own vector), and `labels`, which become its tags. The caption is the
first partition. Each region follows as its own partition, with a url that ends in the media fragment
`#xywh=pixel:x,y,w,h`, so a recall hit says which region it is (`hit.region`). Veil files its images
this way. See [Protos → Visual records](../../Protos/README.md#visual-records).

**Recall carries the record back.** A search asks Thread for each hit's name, group and metadata
(`include_metadata`). `recall(_:as:)` keeps the hits of your type's kind and decodes each payload into
your type. Untyped `recall(_:in:kinds:topK:)` returns every hit with its envelope, Sewn's write-backs
included.

**Sewn writes the same schema.** Sewn's conversation summaries, recap ledger and resonant passages are
`aii-record/1` envelopes of kind `memory`, with the source kinds `sewn-summary`, `sewn-recap` and
`sewn-resonance`. Untyped `recall` returns them like any other record.

Rules worth knowing:
- **Remembering an id again replaces it:** its partitions, its envelope and its graph links.
  `remember` returns once Thread holds the version just sent, and calls to it run one at a time.
- **Supersession files first.** A record with `supersedes` is filed, then the record it replaces is
  removed. Removing first could empty the group and lose its label and access.
- **A record keeps its first group.** To move one, forget it and remember it, or supersede it with a
  new id.
- **A group lives while it holds documents.** Forgetting its last record removes the group too.

Forgetting has four verbs. None of them ever sends an empty Remove, which Thread reads as everything
the owner holds.

| Verb | Removes |
| --- | --- |
| `forget(_ values:)` | these records |
| `forget(documentIDs:)` | the documents behind recall hits (`hit.documentID`) |
| `forget(groups:)` | whole groups, by your ids for them, and everything filed in them |
| `forgetMemory()` | what conversations taught the app: `<app>-memory-<owner>` and `<app>-resonance-<owner>` |

Thread queues a group delete behind earlier writes, so `forget(groups:)` right after `remember` takes
the new records too.

### Owners

An owner is a person within a lane. Every record is filed under one, and a search sees only the owner it
names. Without an account, an app's records go under one of two owners (`AIIOwner`):

| Owner | String | |
| --- | --- | --- |
| `AIIOwner.app(app)` | `local-<app>` | The app's own. A new lane starts with it. |
| `AIIOwner.local` | `aii-local` | Shared by every app that opts in. The Rao apps' lanes start with it: Craft always files here, and Ambient and Veil do when nobody is signed in. |

A signed-in person is `AIIOwner.account(id)`, and an account always wins.

**Opting in** puts your app's local records under the same owner as Ambient's, Craft's and Veil's, each
still in its own lane. It is a choice; an app that makes none keeps its own. Opt in with
`AIIInstance(Notes.self, owner: .local)`, or `AIISupervisor.prepare(owner: .local)` with your own client,
or `aii lanes owner notes aii-local` from a terminal. The owner is written to the lane's entry in the
manifest, and Sewn reads it there, so an app with no account is answered as that owner and `ask`
grounds in the documents `recall` sees. Documents already filed keep their owner until they are filed
again.

**Why a shared owner is safe.** Thread binds a group to the first owner and the first lane that file
into it, and refuses another's. Every app's groups start with its own name, and Sewn's memory groups do
too (`<app>-memory-<owner>`), so two apps under `aii-local` never collide.
[Protos → Owners](../../Protos/README.md#owners) has the wire field and a deposit and search under
`aii-local`.

## Who owns the install

A Mac has one installed build, `aii/bin/AIIServer`, and `aii/install.json` says whose it is:

```json
{
  "contract": 1, "sha256": "…", "installedBy": "aii", "source": "local",
  "checkout": {"path": "/Users/you/src/AII", "commit": "256e699a1c0f", "configuration": "release"},
  "appVersion": "AII 256e699a1c0f", "installedAt": "2026-10-16T09:12:00Z"
}
```

- **`bundled`** is a Rao app's signed helper, which the app installs at launch.
- **`local`** is your own build, which `aii install` builds from a checkout and installs as the stack
  identity, `aii`.

An installer decides in this order:
1. **The same bytes are current.** Nothing happens.
2. **Your command always installs:** `aii install` and `aii update`.
3. **A local build is kept.** No app replaces it, at any contract.
4. **Between apps' bundled builds,** an app installs when nothing is there, when its contract is
   newer, or when it installed the current build and its bytes differ. It never downgrades, and never
   replaces another app's build of the same or a newer contract.

**Trust.** A bundled build runs only when it passes the signature policy. In a release app that means
a hardened Developer ID binary from team `TA6WK7F4P8`. A local build runs when its SHA-256 matches
`install.json` and `install.json` is a regular file of yours with mode 0600. You put it there with your
own command, in your own private home, and anyone who could forge it already runs as you.

**The contract gap.** When an app needs a newer contract than your build speaks, it replaces nothing.
It reports the gap in its status (`AIIStatus.installProblem`):

```
Your AII build is on contract 1; Ambient needs contract 2. Run aii update, or aii uninstall to let Ambient install its own.
```

**Handing back.** Run `aii stop`, then `aii uninstall --yes`. The next Rao app to launch installs its
own copy.

## The long way

`AIIInstance` covers what most apps need. Underneath are the pieces it is made of, for an app that ships
the helper itself, supervises the stack in its own way, or calls the wire directly.

### Ship the helper

Build once with `Scripts/build-servers.sh release`. It writes `.build/release/AIIServer` and
`.build/release/mlx.metallib` (Frigate's Metal step). Put both in your bundle:

```sh
mkdir -p "$APP/Contents/Helpers"
cp "$AII_DIR/.build/release/AIIServer"   "$APP/Contents/Helpers/AIIServer"
cp "$AII_DIR/.build/release/mlx.metallib" "$APP/Contents/Resources/mlx.metallib"
ln -s ../Resources/mlx.metallib           "$APP/Contents/Helpers/mlx.metallib"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/Helpers/AIIServer"   # the helper first, inside-out
```

The metallib lives in `Resources/` and is linked from `Helpers/`, because a plain file in `Helpers/`
counts as nested code to the signature. `AIIInstallPayload.bundled(in:appVersion:)` reads
`Contents/Helpers/AIIServer`, then the metallib from `Helpers/` or `Resources/`. A release build of AII
runs only a hardened Developer ID binary from team `TA6WK7F4P8` (`SignaturePolicy.standard`), or the
person's own build. A debug build accepts any binary. Ambient's and Craft's `scripts/make-app.sh` are
complete examples.

### Supervise

`AIIInstance` holds one `AIISupervisor`. To hold one yourself, keep one per process. It is an actor, so
every call is awaited.

```swift
import AII

enum Index {
    static let stack = AIISupervisor(app: Notes.app)
}

// At launch.
func startIndex() async throws {
    try await Index.stack.prepare(displayName: Notes.displayName)   // ~/.rao, then this app's secret and lane; owner: .local opts in
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    try await Index.stack.install(from: .main, appVersion: "Notes \(version)")  // nil in a dev build with no helper
    try await Index.stack.ensureRunning()              // adopt what runs, or start Sewn then Thread; takes the lease
}

// One status, for a badge.
func followIndex() async {
    for await status in await Index.stack.statusStream() {
        switch status.phase {
        case .up:                    show("Ambient Intelligence Index")
        case .installing(let step):  show(step)
        case .starting:              show("Starting…")
        case .degraded(let why), .down(let why?), .notInstalled(let why?): show(why)
        case .down(nil), .notInstalled(nil): show("Not running")
        }
    }
}

// At quit (and from a SIGTERM handler): drops the lease. The servers stop only when no other app holds one.
func applicationWillTerminate(_ notification: Notification) {
    Index.stack.shutdownSync()
}
```

What the supervisor guarantees:
- **The first app up starts the stack. Every later app adopts it.** Nothing is downloaded twice, no
  model is copied twice, and no second server is started.
- **Installs follow the ownership rules.** `install(from:)` keeps your own build. Between bundled
  builds, the newest contract wins. A server on an older contract is replaced by whichever app finds
  it, and the others follow.
- **A lease per holder.** `aii/leases/<identity>.json` records who needs the stack: an app, or the
  `aii` command. `stop()` and `shutdownSync()` release this app's lease and stop the servers only when
  the last lease is gone, under `aii/run/start.lock`.
- **Proof before trust.** `AIIStatus.ServerDetail.verified` means the process on the port answered a
  challenge with this app's secret. Wait for it before you send anything private.

`AIIStatus.phase` is one of `notInstalled`, `installing(step:)`, `starting`, `up`, `degraded` or `down`.
`AIIStatus.installSummary` names whose build runs, and `installProblem` carries the contract gap.

In development, `aii install` puts your checkout's build in `~/.rao/aii/bin` (see
[the `aii` command](CLI.md)). Or pass
`executables: .init(server: <checkout>/.build/debug/AIIServer, workingDirectory: <checkout>)`.

### Index, search and generate yourself

- **Thread** (gRPC 47090) holds your lane. To deposit, search and walk the graph with the wire types,
  see [Thread → Integrate](../Thread/README.md#integrate).
- **Sewn** (HTTP 47080) runs the models. For chat grounded in your lane, on device or with your key, see
  [Sewn → Integrate](../Sewn/README.md#integrate).

Both read your secret from `secrets/<app>`. Over HTTP, `AIIClient` signs for you:

```swift
let client = AIIClient(app: Notes.app)           // signs X-Ambient-Secret from ~/.rao/secrets/notes
let (sewn, thread) = await client.health()       // a challenge: no secret leaves the process
let stats = try await client.stats()             // this lane: documents, groups, entities, relationships, top entities
let models = try await client.models()           // every pinned model and whether it is on this Mac
try await client.download(model: AIIModels.generalStandard.id)
```

## `~/.rao` (contract 1)

`AIIHome.resolved()` is `AII_HOME` when set, else `~/.rao`.

```
layout.json                       version 1, who provisioned the home and when
secrets/<app>, secrets/aii        one 64-hex secret per registered app (0600), plus the stack's own identity
apps/<app>/                       app-private data only
bin/aii, bin/aii.json             the aii command and the checkout it was built from (Scripts/install-cli.sh)
keys/providers.json               provider keys (Mistral, Tinker), read per call by both servers; written by aii setup, aii keys, aii install (from a checkout's .env) and an app's Settings
keys/device.key                   the device key: 32 random bytes, 0600; kept keys beside it as device-<fp>.key
aii/bin/{AIIServer,mlx.metallib}  the one installed build
aii/install.json                  contract, sha256, installedBy, source (bundled or local), checkout, appVersion, installedAt
aii/aii.env                       SUPABASE_URL, SUPABASE_ANON_KEY (public values only), for apps that ship accounts; written by the installing app, aii keys supabase and aii setup; read by Sewn at start
aii/config.json                   ports and data directories, when moved from the defaults (AIIConfig)
aii/lanes.json                    the lanes manifest (aii-lanes/1): each app's lane id, display name, bundle id, owner, and who registered it and when
aii/sewn/db                       Sewn's data (its node id, wallets, Sinatra state)
aii/thread/db                     the one index
aii/run/{sewn,thread}.{json,log}, start.lock
aii/leases/<identity>.json        who needs the stack; <identity>.pinned.json holds it until released (aii start … aii stop)
models/huggingface/               one copy of every model, for every app (HF_HOME of both servers)
```

Nothing is migrated: a home is provisioned at layout 1 and stays there, and a file that no longer
decodes is treated as absent. `aii reset` (a dry run without `--yes`) brings a home back to a fresh
layout 1. It keeps the secrets, the keys, the lanes manifest, Sewn's data, the index and the models.

## The wire

| | |
| --- | --- |
| `X-Ambient-Secret` / `x-ambient-secret` | the caller's secret on every HTTP request and gRPC call. The secret that matches names the caller and its lane. |
| `X-Ambient-Nonce` + `X-AII-App` on `GET /health` | a launcher's challenge. The server answers `{"stack":"proof","proof":HMAC(secret, "ambient-stack-health-v1:" + nonce),"app":…,"contract":1}` without sending a secret. An open server answers `{"stack":"open","contract":1}`. |
| `contract` | always answered. A supervisor replaces a server on an older contract, whoever holds it. |

Both servers accept loopback only. A server started without `AII_HOME` is **open**: it asks for no
secret and no launcher adopts it. The rules live in `StackSecret`, `StackMode` and `StackChallenge`,
shared by both servers, every launcher and every app.

| Server | HTTP | gRPC |
| --- | --- | --- |
| Sewn | 47080 | 47091 |
| Thread | 47081 | 47090 |

The same for every app (`AIIPortPlan`). `aii/config.json` moves them for every app at once.

## Lanes

Any app can have a lane:
- **Two files make a registration:** `secrets/<app>` (0600), and the app's entry in the lanes manifest,
  `aii/lanes.json`. `AIIInstance.join()` and `AIISupervisor.prepare()` write them the first time, and so
  does `aii lanes add <name>`.
- **Every home starts with the Rao lanes.** Provisioning writes the stack's secret and Ambient's,
  Craft's and Veil's, so their lanes exist before they launch.
- **The first registration wins.** An app that registers a name already taken shares that lane, so
  pick a name that is yours. `aii` is reserved for the stack. The first registration's display name
  stays; an explicit owner updates the entry.
- **A new lane is live at once.** Both servers read `secrets/` again when a secret they don't know
  arrives, at most once every two seconds. An admitted app without a lane is given one.
- **Lanes separate apps' mistakes, not their malice.** Any process running as the person can read any
  secret in `~/.rao`, as it can read the person's other files.

A lane id is `HMAC-SHA256(device key, "rao-lane-v1:" + app)`, truncated to a uuid and written once to
`aii/lanes.json`. The file is the registration, so rotating the key moves no data. Thread derives the
caller's lane from the secret that authenticated the call. A client never names a lane, and the `lane`
field in a message is ignored on a direct call. The stack identity (`aii`) reads every lane, owns none,
and alone may clear the whole index or change the extraction policy.

**The lanes manifest** (`aii-lanes/1`, defined as `aii.v1.LaneManifest` in
[Protos → The lanes manifest](../../Protos/README.md#the-lanes-manifest)) lists every lane on this Mac
with its id, display name, bundle id, owner, and who registered it and when. Both servers read it
through `AIILaneRegistry`, again whenever it changes, at most once every two seconds, so a new lane or
a new owner reaches them without a restart. A file in another format reads as absent and is rebuilt from
`secrets/`, with the same ids. `aii lanes` lists and manages it, in the terminal or the studio's Lanes
screen. Today the servers admit any app whose secret is in `secrets/`. The manifest is laid out so a
later change can make a node admit only the lanes it lists, and `aii doctor` already flags a secret
with no entry.

**The lane doctor.** `aii lanes doctor <name>` (or `d` on the studio's Lanes screen) walks one lane
down the stack, as the app itself, and writes nothing. Each layer passes or says what to fix, and the
first that fails is where to look:

| Layer | Checks |
| --- | --- |
| manifest | the entry is there, and its owner is `aii-local` or `local-<name>` |
| secret | `secrets/<name>` is there, 0600 and 64 hex |
| lane id | the id derives from the device key, or was registered under an older one (shown, not failed) |
| admission | Sewn and Thread each prove the app's secret |
| thread | Thread files the app in the manifest's lane; its documents and groups |
| groups | every group starts with `<name>-`; no document of the owner's is ungrouped |
| records | a sample of up to 50 documents is `aii-record/1`, of this app, under `<name>/<kind>/<id>` |
| owner | the documents are under the owner Sewn answers as; the memory groups |
| logs | recent refusals and errors in `sewn.log` and `thread.log` that name the app or its lane |

`aii lanes remove <name> --yes` removes the secret and the manifest entry. The documents stay in
Thread, and registering the name again finds them, because the lane id is derived from the name.

## Models

| Role | Model | Used by |
| --- | --- | --- |
| `embedding` | rao-studios/voyage-4-nano-mlx-8bit | Thread (every lane), Veil's tiles |
| `generalSmall` | mlx-community/Ministral-3-8B-Instruct-2512-4bit | Ambient's on-device choice |
| `generalStandard` | mlx-community/Mistral-Nemo-Instruct-2407-4bit | Sewn's default, Thread's graph extraction, Craft's worker |
| `generalLarge` | mlx-community/Mistral-Small-3.2-24B-Instruct-2506-4bit | Ambient's on-device choice, Craft's fallback |
| `vision` | rao-studios/Ministral-3-8B-Instruct-2512-mlx-8bit | Sewn's vision slot |
| `coding` | rao-studios/Qwen3-Coder-Next-REAP-48B-A3B-mlx-4bit | Craft's primary |

Every entry carries a 40-hex revision, and no app downloads an unpinned `main`. `AIIModels.kept` (the
standard model and the embedder) is what Sewn never removes. `aii models` lists them, and
`aii models pull <role>` fetches one.

## Signing data

`AIISigningKey(app:)` is the Mac's P-256 key in the shared Keychain (Secure Enclave when available). It
signs blobs such as Rao Verified records and image signatures. Verification is plain CryptoKit:

```swift
let key = AIISigningKey(app: Notes.app)
let signature = try await key.signature(for: blob)             // ES256, raw r‖s, 64 bytes
guard let identity = await key.identity() else { return }
let publicKey = try P256.Signing.PublicKey(compressedRepresentation: identity.publicKey)
let valid = publicKey.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: signature), for: blob)
```
