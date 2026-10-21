[![AII, Ambient Intelligence Index, by Rao Studios: one index, a lane for every app. Three lanes, Ambient in blue, Craft in green and Veil in orange, start as rows of knowledge-graph nodes joined by shared entities; the rows unravel into strands, the strands braid, and the braid tightens into one beam that ends in a gold mark, the index.](Docs/README_Assets/hero.png)](Docs/README_Assets/hero.png)

# AII — Ambient Intelligence Index

AII gives every app on a Mac the same intelligent index, built from three parts:
- **A knowledge graph and vector search** over the person's own data.
- **On-device models** that answer from it with citations.
- **A personal layer** that turns each conversation into memory.

It is installed once per Mac and shared by every app, and each app reads and writes only its own
**lane**. Nothing has to leave the machine.

![The AII stack. Four apps reach two servers over loopback with their own secret: Ambient, Craft and Veil each hold an AIISupervisor and Seam, and your app holds an AIIInstance. AIIServer is one binary in two roles: Sewn on HTTP 47080 and gRPC 47091 (chat, on-device models, the personal layer) and Thread on HTTP 47081 and gRPC 47090 (vectors and a knowledge graph, one lane per app). Seam joins them: Thread registers with Sewn, and Sewn asks Thread. Below sits ~/.rao with the secrets, device key, lane registry, binary, data, leases and one copy of every model. AIIServer is installed once per Mac, and every app keeps the person's own build. A legend explains each numbered region and mark.](Docs/README_Assets/stack.png)

## Getting started

AII is local-first. Sewn and Thread are your Mac's own servers; your apps connect to them over
loopback with a secret, and nothing has to leave the machine. Everything lives in one home, `~/.rao`:
the servers, one copy of every model, a secret per app, and your API key. One key, Mistral or Tinker,
is all you add, and without one the index runs on device. You need a Mac with Apple silicon, macOS 15
and Xcode 26 or later.

**You build your own app on AII.**

```sh
git clone https://github.com/rao-studios/AII.git && cd AII
Scripts/setup.sh              # the toolchain, the packages, then the aii command onto PATH
aii setup                     # asks for one API key, builds and installs AIIServer, starts it, pulls two models
swift run --package-path Examples/Notes
```

`aii setup` provisions the home, asks for one API key (Enter to stay on device), builds and installs
AIIServer unless a Rao app already did, starts the index and pulls the two models it needs. That is
everything. The stack runs with the defaults Ambient's runs with, and your app indexes its data
through Thread and asks through Sewn with its secret: no account, nothing else to configure. Then, in
your app, `AIIInstance(MyApp.self)` and `join()`: see [Join](#join).

**You use Rao apps.** Install Ambient, Craft or Veil. The first one to launch provisions `~/.rao`,
installs AIIServer and starts the index. Signed in to Ambient, type your Mistral key in Settings; it
lands in `~/.rao/keys/providers.json` for every app. Without an account, or from Craft or Veil alone,
give it from a terminal. The app's build is kept:

```sh
git clone https://github.com/rao-studios/AII.git && cd AII
Scripts/setup.sh              # the toolchain, the packages, then the aii command onto PATH
aii setup                     # your key into ~/.rao, the app's build kept, the stack up, the two models
```

**You develop AII.**

```sh
Scripts/setup.sh debug                     # as above, with a debug aii
cp .env.example .env && chmod 600 .env     # set your key; aii setup copies it into ~/.rao
aii setup --debug
aii                                        # the studio
```

`aii install` after each change. `aii keys` lists your keys and `aii keys set mistral` changes one,
live, with no restart. The servers take Frigate (the vendored MLX stack, which also carries
SinatraHarness, the on-device harness) from GitHub. To work on Frigate beside AII, run
`swift package edit Frigate --path ../Frigate`; the build scripts follow it.

**Where `aii` is.** `Scripts/setup.sh` builds the command, puts it at `~/.rao/bin/aii` and links it
into `~/.local/bin` when that folder exists. When neither folder is on your PATH it prints the line to
add to your shell profile, `export PATH="$HOME/.rao/bin:$PATH"`, and `Scripts/setup.sh --add-to-path`
appends it for you. Until a new shell picks it up, `~/.rao/bin/aii setup` works as is. `aii doctor`
checks that `aii` is on PATH.

### Shipping with accounts (Supabase)

Your own app needs none of this. With its secret it indexes and asks with no account: on device with
no key, or through Mistral or Tinker with the one key `aii setup` asks for. Supabase is the accounts
layer the Rao apps ship with (sign-in, Ambient Plus, Rao Verified), and you want it only when your app
will have accounts of its own.

1. Create a Supabase project. Authentication → Providers → Email: on, with "Confirm email" on.
2. Project Settings → API: take the Project URL and the anon public key, never the service-role key.
   Run `aii keys supabase --url <url> --anon-key <key>`, then `aii restart sewn`.

That is enough for sign-up, sign-in, the emailed code (`/v1/auth/verify` takes the code, so the
confirmation template must include `{{ .Token }}`), refresh, sign-out, password reset and your own
profile: no tables. Optional, each route degrading without it: `profiles(id, display_name)` for other
people's names, and `feedback(user_id, message, rating, category)` with an INSERT policy for
authenticated users. The Ambient Plus and Rao Verified migrations are kept outside this repository;
their routes answer 404 or an empty plan until they run. Without Supabase, the auth routes answer 503.

## The parts

| Package | Description |
| --- | --- |
| **[Thread](Docs/Thread/README.md)**, the index | Documents become quantized vectors (voyage-4-nano, on device) and a knowledge graph of entities and relationships (extracted by Mistral-Nemo, on device, or supplied by you). A search lets the graph choose what to scan, ranks it by vector distance, and expands one hop through the graph. Apps deposit, search and walk the graph over gRPC, each in its own lane. |
| **[Sewn](Docs/Sewn/README.md)**, the models and the personal layer | OpenAI-shaped chat and completions, streamed. It runs on device through MLX, or through Mistral or Tinker with a key in the home. Every turn is grounded in the caller's lane and cited. It writes memories and resonant passages back into the lane, and steers sampling with a small per-person network on device. An app needs no account; accounts are for apps that ship them. |
| **[Seam](Docs/Seam/README.md)**, the wire | One set of [protos](Protos/README.md) and the generated Swift every piece compiles against. Apps call Thread directly. Thread dials Sewn and holds a session open, so Sewn can fan requests out to nodes it could never dial. Every call carries the caller's secret, and the secret names the lane. |
| **[AII](Docs/AII/README.md)**, the library your app links | `Core/` is the foundation: the `~/.rao` contract, keys and lanes, the record schema, the pinned model list, and `AIISupervisor`, which installs, adopts and stops the stack. `Join/` is what an app holds: `AIIInstance`, one actor to join, remember, recall, forget and ask. No MLX and no server code. The [`aii` command](Docs/AII/CLI.md) manages it all from a terminal. |

## Join

For the person, install any AII app, or build AII from this repository with `aii install`, and the
index is there. Every later app finds it running and takes a lease: there is no second server, no second
copy of a model, and one status. Every app keeps the person's own build. For the developer, joining is
one dependency, two declarations and one actor:

![Join the index in six steps. 1 Depend: the AII package by URL with traits: [], product AII. 2 Describe your lane: an AIIAppDescriptor with static let app: AIIApp = "notes"; join() writes secrets/notes, the lane and apps/notes/, and the running servers admit it at once. 3 Describe your record: struct Note: AIIRecordable, filed in an aii-record/1 envelope that carries your value back whole. 4 Join: AIIInstance(Notes.self), then join(), which registers the lane, installs a bundled helper, adopts or starts the stack and waits for proof. 5 Remember and recall on Thread, gRPC 47090, in your lane; Notes come back as Notes. 6 Ask Sewn on 47080, on device or with your key, grounded and cited; forget a group, or forgetMemory().](Docs/README_Assets/join-guide.png)

```swift
// Package.swift: the servers stay out of your build
.package(url: "https://github.com/rao-studios/AII.git", branch: "main", traits: []),
.product(name: "AII", package: "AII"),
```

```swift
import AII

enum Notes: AIIAppDescriptor { static let app: AIIApp = "notes" }    // your lane

struct Note: AIIRecordable {                                         // what you push into it
    static let kind: AIIRecord.Kind = "note"
    static let group = AIIRecord.Group(id: "notes", label: "Notes")
    var recordID: String, title: String, body: String
    var text: String { body }
}

let aii = AIIInstance(Notes.self)
try await aii.join()                                                 // register the lane, adopt or start the stack
try await aii.remember(notes)
let found = try await aii.recall("who leads Joltvault?", as: Note.self)   // Notes come back as Notes
for try await event in aii.ask("Who leads Joltvault?") { show(event) }    // grounded, cited: on device, or your key
```

[`Examples/Notes`](Examples/Notes/Sources/Notes/main.swift) is this app, complete, and
[AII → Join](Docs/AII/README.md#join) walks through it. Every app files its records in one schema,
`aii-record/1`, [defined in Protos](Protos/README.md), so recall reads the same way in every app. A
picture is a record too, with its regions as partitions. Without an account, an app files under its
own owner, `local-<app>`, or opts in to `aii-local`, the owner Ambient, Craft and Veil share. To manage
the index on this Mac, double-click `Scripts/aii.command`. It opens the `aii` studio, where `2` lists
every lane in the lanes manifest and `d` checks one.

## What's different

- **One index for every app, partitioned by lane.** Apps share one graph and one vector space, and
  entities merge across them. Each app still reads and writes only the lane its secret names, and a
  graph edit is refused unless every document behind it is in the editor's lane.
- **Graph and vectors in one search.** The graph decides what is worth scanning and what to add, and
  the vectors decide the order. Each result carries a trace of what the graph matched.
- **Memory that grows.** Conversations become documents in the person's lane: summaries, resonant
  passages and a running recap. The next turn retrieves them like anything else.
- **Personal without a fine-tune.** On device, SinatraHarness learns per person which passages
  actually ground an answer, and biases sampling toward them. The model's weights never change, and
  nothing is sent anywhere.
- **One install, one copy, one status.** Your own build, installed with `aii install`, is kept by
  every app; otherwise the newest bundled build wins. The last app out stops the servers. Every model
  is pinned to a commit in one file and kept once for every app.

Building a MuseAI or Codex-class app on macOS has meant building this infrastructure first: a
private index of the person's world, models that answer from it on device, memory that compounds,
and a coding model. AII ships all of it as one dependency. Ambient (text), Craft (code) and Veil
(visuals) are built this way today. A competitor to any of them starts from a working index, models
and memory on its first night, not after a year of plumbing.

## Why gRPC

The index's own traffic runs over gRPC, not REST: apps call Thread on 47090, and Thread holds a
session with Sewn on 47091. It is a closed wire between two parties that compile the same protos.
It carries what REST handles worst: vectors by the thousand, on the path of every chat turn and
every recall.

- **Latency.** One HTTP/2 connection carries many calls at once, with no handshake per request, and
  messages decode from binary instead of being parsed as JSON.
- **Throughput.** A vector is 1,024 packed floats, 4 KB on the wire; as JSON text the same numbers
  take about 3.5 times that. A picture with its tile vectors runs to about 5 MB, and AII's client
  sends up to 32 MB in one request. Streams run both ways: Thread dials Sewn once and holds the
  stream, so Sewn can send requests to a node it could never dial.
- **Security.** Every call carries the caller's secret in its metadata. Seam's interceptors refuse a
  call without a secret the server knows, or from beyond loopback. The secret names the lane; a
  client never does.
- **A closed contract.** Both ends are generated from [`Protos/`](Protos/README.md), so a field can't
  drift between them. No browser and no third party speak this wire, so there is no public surface
  to version for strangers.

REST stays where the other side is a person, a shell or the wider ecosystem: Sewn's OpenAI-shaped
chat with streamed tokens on 47080, Thread's routes for stats, search and ingest from `curl` on
47081, and the `/health` challenge every launcher sends.

## Scripts

Every script works on the checkout it lives in, and takes `[debug|release]` where it builds.

| Script | Run | What it does |
| --- | --- | --- |
| `Scripts/setup.sh [debug\|release] [--add-to-path]` | once, after cloning | Checks the toolchain this Mac needs (Apple silicon, macOS 15, Swift 6.2, the Metal toolchain, downloading it when Xcode lacks it) and resolves every package from GitHub, Frigate included. Then it builds the `aii` command and puts it on PATH through `install-cli.sh`. When `aii` isn't reachable it prints the line to add; `--add-to-path` appends it to your shell profile. It stops before the long server build and says what comes next: `aii setup`. |
| `Scripts/install-cli.sh [debug\|release]` | what `setup.sh` runs; again after CLI changes | Builds the `aii` command only and puts it at `~/.rao/bin/aii`, with `aii.json` beside it naming this checkout (which is where `aii install` builds from). Links it into `~/.local/bin` when that folder exists, and prints the PATH line when needed. Default release. A running `aii` keeps its file. |
| `Scripts/aii.command` | double-click in Finder | Opens the `aii` studio for this checkout, building `aii` the first time. If the build or the studio fails, the window stays open with the exit code. |
| `Scripts/cli.sh [arguments]` | while working on the CLI | Runs `aii` from this checkout without installing it: builds when the sources are newer than the binary, then runs it with your arguments (`Scripts/cli.sh status`). `AII_CONFIG=release` builds release; `AII_SKIP_BUILD=1` reuses the last build. |
| `Scripts/build-servers.sh [debug\|release]` | what `aii install` runs | The one place the servers are built: `swift build --product AIIServer`, then the Metal library beside it, into `.build/<config>/{AIIServer,mlx.metallib}`. Default release. The Rao apps' packaging scripts call this and copy from here. |
| `Scripts/build-metallib.sh [debug\|release]` | after `swift build`, before an on-device test | Compiles MLX's Metal shaders into `mlx.metallib` beside every binary and test bundle in `.build/<config>/`. Frigate owns the shaders and the compile; this finds Frigate's script in SwiftPM's checkout, or in an edited `Packages/Frigate` (`FRIGATE_DIR` overrides both). SwiftPM has no Metal step, so without this the first model load aborts. |
| `Scripts/generate-seam.sh` | after editing `Protos/*.proto` | Regenerates the Swift: `thread.proto` and `fleet.proto` into `Sources/Seam/Generated` (the wire), `record.proto` and `lanes.proto` into `Tests/AIITests/Generated` (the conformance tests only). Both plugins are built from this package's resolved checkouts, so the generated code always matches the runtime it links. Needs `protoc` on PATH (`brew install protobuf`). |
| `Scripts/test-all.sh [filter]` | before a commit | Every suite in one `swift test`, then a build of `Examples/Notes`, so a change that breaks what an app writes breaks here. With a filter, that suite only; prefix the module, because class names repeat (`'SewnTests.StackSecretTests'`). The live on-device tests stay opt-in behind their `SEWN_*_TESTS` and `THREAD_*` variables. |
| `Scripts/test-local-sinatra.sh [arguments]` | to exercise on-device Sinatra | Sewn's on-device SinatraHarness suite, the live two-turn test included. It strips any metallib from the test bundles (a copy made before the build breaks their signature), builds, installs the metallib and runs `SewnTests.LocalSinatra`. `SEWN_LOCAL_SINATRA_MODEL` picks the model. |

## Layout

```
Sources/AII/Core/   library   the foundation: the ~/.rao contract, keys, lanes, the record schema, models, launcher, supervisor, client
Sources/AII/Join/   library   what an app inherits and holds: AIIAppDescriptor, AIIRecordable, AIIInstance
Sources/Seam/       library   the gRPC wire: generated Thread_V1_* / Fleet_V1_*, sessions, interceptors
Sources/Sewn/       library   the HTTP/WS server (Swift 5 mode)
Sources/Thread/     library   the index (Swift 6 mode)
Sources/AIIServer/  binary    AIIServer sewn | thread | probe
Sources/AIICLI/     binary    aii: setup, status, doctor, install, start and stop, keys, lanes, models, reset, and the studio
Examples/Notes/     package   the smallest app on the index, built as a custom app builds it
Protos/             schemas   the wire (thread, fleet) and the record and lanes manifest (record, lanes); see Protos/README.md
Tests/  Docs/{AII,Seam,Sewn,Thread,README_Assets}/  Scripts/
```

`Docs/README_Assets/src/build.sh` rebuilds the README images. AII was assembled from Seam, Sewn and
Thread. GPL-3.0 (see [LICENSE](LICENSE)).

> *"She seemed to know, to accept, to welcome her position, the citadel of the family, the strong place that could not be taken." — John Steinbeck*