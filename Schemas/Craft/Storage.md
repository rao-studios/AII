# craft-storage/1

> Published from Craft's `Schema/Storage.md` at `ec26141c` by `Scripts/schema/publish-aii.py`. Edit it there: this copy is replaced on every publish.

Where everything Craft keeps lives, in what shape, who writes it and who reads it. **The AII folder is the
project's whole memory: move it to another Mac and every project works unchanged.** What is not in AII is either
rebuilt from the project's files or belongs to this Mac on purpose (§9).

| File | What it describes |
| --- | --- |
| [`craft-record.schema.json`](craft-record.schema.json) | A record (`craft-record/1`), its payloads, the ledger and an export row (§4, §6) |
| [`craft-index.schema.json`](craft-index.schema.json) | Every document in `craft-index` as AII holds it: its kinds, their ids and entities, each payload (§2, §6, §7) |
| [`code-card.schema.json`](code-card.schema.json) | A code card (`craft-card/1`), what `craft-code` holds (§8) |
| Craft's `Docs/craft-turn.schema.json` | A turn record (`craft-turn/1`), this Mac's log of one turn (§9) |

All four are generated from the code (`RecordSchemaJSON`, `IndexGroupSchemaJSON`, `CardSchemaJSON`,
`TurnRecordSchemaJSON`); `CRAFT_UPDATE_GOLDEN=1` rewrites them, and a test fails when they drift — another builds each
`craft-index` document as the stores do and holds it to its schema. AII's repository keeps a copy of this document and
the schemas of what is in AII, under `Schemas/Craft/`: `Scripts/schema/publish-aii.py` writes it, and it is never edited
there.

## 1. Layers

Four layers, each named for what it is. Only the second is knowledge Craft learned or was told.

| Layer | Contents | Stored | Written by | Read by |
| --- | --- | --- | --- | --- |
| **Code index** (derived) | code cards — and so how the project writes code | AII (`craft-code`) and this Mac's index | the watch engine (`ProjectWatch` → `LazyThreadIndex`) | retrieval, the knowledge window |
| **Craft records** (learned or told) | `project`, `approach`, `lesson`, `note`, `instruction` — each with evidence and staleness; the lessons every project shares, every workflow's | AII (`craft-records`, `craft-index`) | the record keeper (`RecordKeeper`), `InstructionsStore`, `WorkflowLessonKeeper` | retrieval, the prompt, the knowledge window; workflow lessons a workflow's `lessons` step and the pack's lesson cards |
| **Bookkeeping** (not knowledge) | the recall ledger; project settings | AII (`craft-index`) | the keeper; `SettingsStore` | the keeper, `ConfigStore` |
| **Local only** | turn logs, the screenshots a request attached, the text of the documents it attached, the AIIs Craft asks, global app config, the outbox | `~/.rao/apps/craft/…`, `~/Library/Application Support/Craft/config.json` | the turn, the AIIs window and `craft aii`, Settings | Lantern, every session's sourcing, every process |

## 2. Groups

Everything Craft files is an `aii-record/1` envelope (AII's record schema) in Craft's lane, under the owner the Rao
apps share with no account, `aii-local`. Every group begins `craft-`, every document `craft/`; one remove guard
(`ThreadDocuments`) refuses an empty id list and anything outside those prefixes.

| Group | Holds | Searched |
| --- | --- | --- |
| `craft-records` | approach, lesson and note records; the workflow lessons, every project's under the key `learned` | yes — the record query (`ThreadBoot.searchRecords`), which drops a project's lessons (they come by place) and notes a workflow lesson by meaning for the lesson cards; the keeper reads workflow lessons by their prefix (`craft/lesson/learned.`) |
| `craft-index` | the project record, instruction records (every project's under the key `user`), the recall ledger, the settings | no — read by prefix |
| `craft-code` | every project's code cards, one document per file; the project is the id's first segment (`<scope>.`) and the entity `project:<scope>` | yes — code queries: this project's by its id; every project's that the graph links to it, as reference, when the session reaches every project |

`craft-index` is bookkeeping as much as knowledge, and none of it is found by meaning, so an indexer knows each
document by its kind, its id and its payload ([`craft-index.schema.json`](craft-index.schema.json)):

| Document | `kind` | Envelope id | Payload | Entity |
| --- | --- | --- | --- | --- |
| The project record | `project` | `<project key>.pj-<16 hex>.<v16>` | a `craft-record/1` record with `reading` | `record:pj-…` |
| Instructions | `instruction` | `<project key>.in-<16 hex>.<v16>` (`user` for every project) | a `craft-record/1` record with `instruction` | `record:in-…` |
| The ledger | `ledger` | `<project key>.<v16>` | `{"type":"ledger","ledger":<craft-ledger/1>,"path"}` | `ledger:<project key>` |
| Settings | `settings` | `<project key>.<v16>` | `{"format":"craft-settings/1","project","label","path","settings","writtenAt"}` | `settings:<project key>` |

Each is one document a version, `supersedes` naming the version it replaces; the document's id is
`craft/<kind>/<envelope id>`. Its text is a heading and a summary — the claim, the ledger's counts, the settings' JSON —
only so the document is not empty: nothing searches it.

A group is a search scope, so only what is searched differently has one: the code cards, the records a turn finds by
meaning, and everything else about a project. A group lives while it holds documents; Settings' explorer deletes one whole (`LaneDeletion`), and a live keeper
reads AII again rather than write back from memory.

## 3. Document ids

| Document | Kind | Id |
| --- | --- | --- |
| Record | `approach`, `lesson`, `note`, `instruction`, `project` | `craft/<kind>/<project key>.<record id>.<v16>` |
| Ledger | `ledger` | `craft/ledger/<project key>.<v16>` |
| Settings | `settings` | `craft/settings/<project key>.<v16>` |
| Code card | `code` | `craft/code/<scope>.<path key>.<hash>` |

- **`<project key>`** is the project's id when it is a plain name (`g0a7fe5079e7a`, `n-shop`), else `h` and 12 hex of
  its hash (`CraftThreadAddress.projectKey`). What holds for every project is under the key `user`
  (`ProjectIdentity.everyProject`); what every project's workflows learned, under `learned` (`RecordProject.learned`).
  Neither can be a project's id, which is always `g…`, `n-…` or `h…`.
- **A project's id** is its repository's first commit (`g…`), so every clone of one repository is one project; a
  folder with no commit is `n-<name>` until it has one, and then its instructions, settings, records and ledger move
  to the commit's id when a session next opens it (`IdentityMove`, the one place a change of identity is followed).
- **`<record id>`** is deterministic: the kind's prefix and 16 hex of a hash over the format, the kind, the project
  and what the record is about (`RecordID`). Two writers of one fact write one record.
- **`<v16>`** is 16 hex of the content's hash: every version is a document of its own. A write files the new one,
  naming the one it replaces in the envelope's `supersedes`, reads it back, then removes the older; a load keeps the
  highest revision, its bytes breaking a tie, so two writers converge (`RecordStore`).

## 4. A record

`craft-record/1` (`Record`, `RecordCodec`): canonical bytes — sorted keys, ISO-8601 to the second, nils omitted,
evidence in a fixed order. A key this build does not know is kept and written back; a kind, status, source or
format it does not know makes the record **inert**: read and kept, never rendered, rewritten or removed. A record
of another format is inert, and its id hashes that format, so nothing written before can come back. Every format stays
at `/1` while Craft is 0.0.0: a change to a record's shape changes `/1` in place and starts fresh.

| Key | What it holds |
| --- | --- |
| `format`, `id`, `kind`, `revision` | the format; the deterministic id; the kind; raised on every write |
| `project` | the project it belongs to: id and label |
| `claim`, `claimBy` | one sentence; `craft`, `model` or `person` |
| `scope` | the language, what the work was made with (the workspace reading's stack words), the paths it is about |
| `source` | `observed`, `turn`, `stated` or `workflow`, with the detector, session, plan, rounds, model |
| `status` | `candidate` → `verified` \| `superseded`; `supersedes` / `supersededBy` link the chain |
| `createdAt`, `statusChangedAt`, `lastValidated` | when it was made, last moved, last found true |
| `evidence` | up to 16 pointers that would prove it wrong (§5) |
| `approach`, `lesson`, `instruction`, `reading`, `learned` | the kind's payload |

| Kind | Id | `claimBy` | `source` | Written by | Evidence | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `project` | `pj-` · the project | `model` | `observed` (`workspaceReading/1`) | `RecordKeeper.keepReading`, when a build turn's setup step read the workspace; only when the reading changed | the files its commands were read from, as anchors | candidate |
| `approach` | `ap-` · the plan | `model` | `turn` | `RecordKeeper.keepApproach`, when files changed and every check passed after the last edit (`PlanSupervisor`) | anchors (symbols, files), checks with the commands that ran | verified only when the plan completed with a unit or run check and, with a goal, the judicator's reading; candidate otherwise |
| `lesson` | `ls-` · place + failure | `craft` | `turn` | `RecordKeeper.keepLessons` (`LessonProjector`), whether or not the plan completed | the file it failed in | candidate |
| `note` | `nt-` · the claim | `model` or `person` | `turn` or `stated` | `remember` | the files and symbols it names | candidate |
| `instruction` | `in-` · the project | `person` | `stated` | `InstructionsStore`; one record a project, revised; cleared is a record with no words, never said is no record | none | verified |
| `lesson` (workflow) | `ls-` · `learned` + the failure's pattern + the fix | `craft` | `workflow` | `WorkflowLessonKeeper.keep`, when a workflow confirmed and its agent's report ended with `cause:` and `fix:` (`WorkflowLessonOps.learning`, kept by `WorkflowDoor.learn`); the same pattern fixed the same way in another project, or by another workflow, raises `confirmed` and adds it to `seenIn` | none: a project's file means nothing in another | candidate; its standing is `confirmed − missed`, and it is never recalled once `missed > confirmed` |

The project record's payload is the workspace reading (`craft-reading/1`, `WorkspaceReading`): a summary, the stack
words, and the parts — each a folder, what it is, and the commands that build, check, run and serve it, each with the
file and line it was read from, or why it will not run here — with the files it read and their digest. It is what the
session's model read off the workspace's own files (`SetupAgent`), never what a run proved: the checks that passed in
earlier work (an approach's check evidence, with its command) outrank it wherever both are said. An approach and a note
are scoped by its stack words.

A workflow lesson's payload is `learned` (`WorkflowLesson`): the `workflow` that first kept it (`resolve`,
`workaround`), the failure's `pattern` — its language, the tool (the command's program and first word that is neither a
flag nor a path), the toolchain's code when the line gives one, and the first error line with paths, numbers and quoted
names masked; a check the judicator read has the tool `judicator`, the reading's kind as its code and no line — the
agent's `cause` and `fix`, one line each, `confirmed` and `missed`, and the projects it was `seenIn`. It belongs to no project's keeper, so retention never sweeps
it. A turn's pack carries it as a lesson card (`CodeContextRetriever+LessonCards`) when a check of the open plan failed
with its pattern or one like it, or when the record query found it by meaning in a language the workspace is in. Two writers — the app and `craft` — may score one lesson at once: revision adoption
keeps every record, but a count raced by both can lose one increment. Accepted for v1.

## 5. Evidence and staleness

**Staleness is computed, never stored.** Each pointer is checked against the live index whenever a record is read
(`RecordCheck`): the file or symbol is gone → **contradicted**; its hash moved → **drifted**. A symbol is found by what it is, not only by its id (moved, renamed, an extension by the
type it extends). Anchors decide; other pointers escalate at half their weight. A stale record ages in days of the
project's use and goes past the retention window (`RecordRetention`); fresh, stated and inert records never age.

## 6. The ledger

`craft-ledger/1` (`ProjectLedger`), one a project, merged, never overwritten:

| Key | What it holds |
| --- | --- |
| `useDays` | the days the project was open or ran a turn — what retention counts |
| `files` | each file a record cites: its revision and hash |
| `recall` | per source key: placed, consulted, credited, and the last turns |

Source keys: a record's id (`ap-…`, `ls-…`, `nt-…`); a card, `code:<path>#<name>`; reference, `project:<scope>/<id>` and `aii:<id>/<id>`. Written when a day of use begins, at the end of a turn
that wrote files, as a session closes, and otherwise at most every ten minutes; when the ledger outgrows an envelope
the sources recalled longest ago drop first.

## 7. Settings

`craft-settings/1` (`SettingsStore`): the project's layer of Craft's config, one document a project. Config
resolves in order: the defaults, then the global layer (`~/Library/Application Support/Craft/config.json`), then the
project's layer **read from AII**, then a session's overlay (`ConfigStore`). The project layer is held in memory for
the process (`ProjectSettingsLayer`) and has no file: it is read from AII when a session opens and before an index
pass or `craft` command uses the config (`ThreadOps.loadProjectSettings`, within 10 s); a write updates it once it
reads back. With AII out of reach the project layer is empty, and the session and the CLI say so.

## 8. The code index

**Cards** (`craft-card/1`, Craft's `Docs/code-cards.md`): one per function, type and file, filed per
clone under its scope in the one code group, so two clones at different paths keep their own; this Mac's copy is under
`~/.rao/apps/craft/index/<scope>/`. An export leaves them out: they are rebuilt from the files.

**One group, three lanes in the explorer.** Records, Index and Code are Craft's three groups. A code search keeps this
project's cards by the id they start with, after naming `project:<scope>` so the node raises them and asking for three
times the hits (`LazyThreadIndex.search`). Each document names `project:<scope>` and carries the project's `label`
(its folder's name) in its payload, which is how a card from another project is cited.

**The graph says how projects relate, never how code calls.** Each document sends a small set of relationships:
`project:<scope> imports module:<M>` for each module the file imports, `project:<scope> declares module:<own>`,
`module:<own> declares sym:<Type>` for its top-level types (`file:<path> declares sym:<Type>` for a file in no module, such as an Xcode app's sources), and `sym:<Type> conforms|inherits sym:<P>` (or `type:<P>`).
Those are the parser's facts. **What a type is for is Thread's reading**: a deposit filed with `relate_code`
(`index.codeRelations`, on by default, Settings › Knowledge › Relations) is read once more by Thread's on-device model
after it is filed, for the types the file declares only, and Thread adds `sym:<Type> serves <goal>` and `project:<scope> pursues <goal>`, a goal being an
entity of kind `goal` named by a short phrase. Thread offers the goals it already holds nearest the file first, so two
projects solving the same problem meet at one goal; Craft writes none of it and keeps no list. Two projects are linked
when one declares a module the other imports, or both pursue a goal, found two hops from the project's entity
(`ThreadBoot.linkedProjects`). Importing the same module links nothing: every project in a language imports its
standard library. That link, a score over the reference floor and the turn's language are what let another project's
card into a turn that reaches every project (`OtherProjects`, the context chip's Reach). Calls, references and members
stay in this Mac's index, read live.

A card holds one unit as written: `fn`, `type`, `file`, and `window` for code no analyzer reads. Its calls are in the
order they are made, its members in the order they are declared, the clauses a type inherits and conforms by as
written, and a file card lists what the file declares and imports. **How a project writes code is in its cards**: a
model shown a folder's cards writes the next file the way the folder does, so no rule about it is counted, kept or
placed. For a file a turn will create, the pack places the cards of the newest file beside it — same folder, same
language: its file card and its main type's (`CodeContextRetriever.besideCards`); for code that exists, its own cards
and their neighbours already are the pack.

## 9. Local only, and why

Under `~/.rao/apps/craft/` (`AII_HOME` moves `~/.rao`):

| Path | What | Why it is not in AII |
| --- | --- | --- |
| `index/<scope>/` | this clone's code index | derived: rebuilt from the files |
| `turns/<project id>/` | one `craft-turn/1` record a turn | this Mac's runs, a log, not knowledge |
| `lantern/<project id>/` | Lantern's grades of steps | this Mac's review of its own runs |
| `captures/<project id>/` | the screenshots a request attached, one PNG each, pruned with the turn logs that name them | this Mac's pictures of its own screen; the turn keeps what the vision model read in them, never the picture |
| `attachments/<project id>/<session id>/` | the text of each document a request attached, read when it was attached; deleted once the turn placed it whole, else when its session closes, and every folder when the app starts | the person's own files, read for one conversation: the turn's block holds what the model was shown, nothing is kept past the session |
| `aiis.json` | the AIIs Craft asks for knowledge, and which are connected (`craft-aii-connections/1`) | this Mac's connections: what each one is is asked of it, and every session's sourcing reads the file |
| `outbox/` | records and ledgers AII has not confirmed yet | in transit: filed and removed on the next contact |
| `agents/`, `rules.json` | installed agent runners; "Always allow" rules | this Mac's software and permissions |

And `~/Library/Application Support/Craft/config.json`: the global config — models, appearance, retrieval switches —
machine-wide, not a project's.

## 10. Portability

Move the AII folder and every project comes with it: its project record, approaches, lessons, notes, instructions,
ledger and settings are AII documents keyed by the project's commit id, which every clone shares. The code index is
rebuilt from the files on the first pass; the AIIs Craft asks are this Mac's own connections. Nothing a project needs is a file inside the project, and nothing is a copy that could disagree with AII.

## 11. Starting fresh

`craft thread reset --all` empties Craft's part of AII for every project (`ThreadOps.forgetEverything`): every
`craft-` group goes, the lane is cleared (with the graph's entities and relationships its documents mention; one another
lane's documents also mention stays, as that lane's), the outbox is emptied, and the in-memory settings layer is dropped.
It reads the lane's counts back from the node and refuses to call it done while any document or entity is left. It refuses while Craft runs, since a live keeper writes what it holds back as it quits. Other apps'
lanes are untouched. Code cards are filed again as projects open; instructions and settings must be told again.
`craft records export --archive` first keeps a copy; nothing older is ever translated in. `craft thread forget --all`
does the same for one project.
