# ambient-storage/1

> Published from Ambient's `Schema/Storage.md` at `2f7948f` by `scripts/schema/publish-aii.py`. Edit it there: this copy is replaced on every publish.

Where everything Ambient keeps lives: in what shape, who writes it and who reads it. **AII holds what Ambient
learned from what the person read and said. What is not in AII is this Mac's settings, its keys, or state held
only while Ambient runs (§8).**

| File | What it describes |
| --- | --- |
| [`ambient-reading.schema.json`](ambient-reading.schema.json) | A reading (`ambient-reading/1`): the envelope Ambient fixes, the payload, the card's lines |
| [`ambient-exchange.schema.json`](ambient-exchange.schema.json) | A turn or a remark (`ambient-exchange/1`) |
| [`ambient-ledger.schema.json`](ambient-ledger.schema.json) | The reading ledger (`ambient-ledger/1`) |

All three are generated from the code (`AmbientSchemaJSON`). `AMBIENT_UPDATE_GOLDEN=1` rewrites them and a test fails
when they drift (`AmbientSchemaTests`). Another test builds each record the way the store does and holds it to its
schema, and a third holds this document to the code. AII's repository keeps a copy of this folder under
`Schemas/Ambient/`. `scripts/schema/publish-aii.py` writes it, and it is never edited there.

## 1. Layers

| Layer | Contents | Stored | Written by | Read by |
| --- | --- | --- | --- | --- |
| **Reading** | what was in front of the person: a card, its passages, its pictures | AII (`ambient-reading-<owner>`) | the reading indexer (`ReadingIndexer` → `ThreadContextStore.depositReading`), after 12 s of quiet on a page | Sewn chat, PastRecaller, ConnectionProbe, Machine recall, the Index pane |
| **Exchanges** | what was said: a turn, a remark she made unasked | AII (`ambient-exchange-<owner>`) | the brain, after a turn or a delivered insight (`depositExchange`) | Sewn chat, PastRecaller, Machine recall, the Index pane |
| **Bookkeeping** | the reading ledger | AII (`ambient-index-<owner>`) | `ThreadContextStore.persistReadingManifest` | the indexer at launch, by id |
| **Link** | an iPhone's notes | AII, Link's lane (`link-<owner>`), not Ambient's | `ThreadContextStore.depositSeerNote` with Link's credential | Sewn chat, iPhone sources |
| **Local only** | settings, the chat page, keys, what is held while Ambient runs | this Mac | Settings, the chat service, the runtime | Ambient |

## 2. Groups

Everything Ambient files is an `aii-record/1` envelope (AII's record schema) in Ambient's lane, `ambient`. It is
filed under the signed-in account, or under `aii-local` with nobody signed in: the owner the Rao apps share, which
a sign-in claims (§7). Every group is per owner: Thread binds a group to the first owner that files into it.

| Group | Holds | Searched | Format |
| --- | --- | --- | --- |
| `ambient-reading-<owner>` | `reading` | yes, by meaning | `ambient-reading/1` |
| `ambient-exchange-<owner>` | `turn`, `insight` | yes, by meaning | `ambient-exchange/1` |
| `ambient-index-<owner>` | `ledger` | no, read by id | `ambient-ledger/1` |

A group is a search scope, so only what is searched differently has one. Sewn's chat scope
(`ThreadMemoryTopology.sewnPersonalScope`) is the reading and exchange groups, Link's group once an iPhone's notes
were filed, and Sewn's own two. It never includes the index group.

**Others in the lane.** Sewn files its memory of Ambient's conversations into Ambient's lane:
`ambient-memory-<owner>` (summaries and the chat recap) and `ambient-resonance-<owner>` (resonant passages), kind
`memory`. They are Sewn's (AII's `Sources/Sewn`), and Ambient reads them but never writes them. `ambient-thread-probe`,
a development tool, files kind `probe` into `ambient-probe-<owner>`. Nothing reads those records.

**Link.** An iPhone's notes are not Ambient's. Link is AII's shared lane for what a linked device sends: kind
`note`, `link-note/1`, one group `link-<owner>`, composed by AII's `AIILinkNote` (AII's `Schemas/Link/`). Ambient files
a note with Link's credential, which AII derives from the device key. Every lane reads Link, and only Link's
credential removes a note. The note's folder on the iPhone is a field of the note, never a group.

## 3. Document ids

| Document | Kind | Id |
| --- | --- | --- |
| Reading | `reading` | `ambient/reading/<16 hex>`: FNV-1a of the owner, `\|`, the identity key |
| Turn | `turn` | `ambient/turn/<16 hex>`: FNV-1a of the owner, `\|`, the turn's id |
| Remark | `insight` | `ambient/insight/<16 hex>`: FNV-1a of the owner, `\|`, the remark's id |
| Ledger | `ledger` | `ambient/ledger/<16 hex>`: FNV-1a of the owner |

- **The owner** is lowercased, as Thread and Sewn spell it, and canonicalized (whitespace collapsed).
- **The identity key** is the material's owner-free identity: its bundle id and its document (path, URL or
  title), canonical (`ReadingMaterial.identityKey`). A re-read of the same page replaces its record.
- **Every id is keyed on the owner.** Thread keeps a document's files by id alone, so a copy filed for another
  owner (a claim) never shares an id. An id has one shape, filed or claimed.

## 4. The formats

Every payload names its `format`. A record of another format is not read: the claim skips it and the ledger reads as
none. No payload repeats the envelope's `id` or `title`, and no payload holds the words: those are the partitions.

**`ambient-reading/1`** (`ReadingRecord`). The payload is what the card says (`identityKey`, `app`, `bundleID`,
`identity`, `url`, `precis`, `concepts`, `contentHash`, `capturedAt`, `characters`), `pictures` (`located`,
`described`, `names`), and `layout`: which partition is which, as inclusive ranges. The tags are the concepts. The
graph is declared: the page (`page` or `document`), the app, each concept and each described picture (`image`),
with `read in`, `mentions` and `shows`. The partitions, filed whole and never split again:

1. **The card**, one fact a line:
   - `Page: <title>` (read at a URL) or `Document: <title>`
   - `Read in: <app>`
   - then, when known: `At: <url>`, `Summary: <précis>`, `Concepts: <a, b>`, `Pictures: <n> on the page, <m> described`
2. **The passages**, the page's own words in paragraphs, at most 400.
3. **The pictures' descriptions**, `[Image n] caption — description`.

When a page is mostly pictures, the pictures come before the passages. What leads is what a search finds it by.

**`ambient-exchange/1`** (`TurnRecord`, `InsightRecord`). The payload holds `exchangeID` (the turn's or remark's own
UUID), `capturedAt`, `askedOn` (`mac` or `iphone`), and `materialTitle`. It also holds `reading`: the
`ambient/reading/<id>` that was in front, so an exchange leads back to what it was about. There is one partition of
at most 6,000 characters:

- `They asked: <their words>` (a turn)
- `<her name> said: <reply>` or `<her name> noticed: <remark>`
- `While reading: <title>`

There are no tags and no declared graph: Thread extracts one from the words.

**`ambient-ledger/1`** (`ReadingLedgerRecord`, `UnitIndexManifest`). The whole ledger is the payload: `format` and
`entries`, keyed by identity key. Each entry holds:

| Key | Holds |
| --- | --- |
| `contentHash` | the revision |
| `concepts` | the annotator's concepts |
| `pinnedConcepts` | a person's correction, which replaces the annotator's |
| `annotation` | why the concepts look as they do |
| `precis` | the annotator's sentence |
| `visuals` | what each picture shows, by the picture's hash |
| `indexedAt` | when this revision was indexed |
| `lastSeenAt` | when it was last in front of the person |
| `filedAt` | when this revision reached AII |

Its one partition is a summary line, `Reading ledger: <n> readings`, so Thread embeds nothing big. One `other`
entity keeps Thread's extraction off it.

## 5. The ledger

The ledger is what lets a relaunch resume: a page whose content hash it already holds is not read again.

- **It names only what AII holds.** A row is written once its reading's revision was filed (`filedAt`), or when a
  person pinned its concepts. A reading still waiting for Thread is not in the ledger, so a relaunch reads it again.
- **It is written from one copy.** It is written from the indexer's catalogue as it stands (`ledgerSource`), within
  60 s of a deposit. A Forget, a Re-read, a pin, retention and the claim write it at once.
- **An unread ledger is never overwritten.** The ledger is written for an owner only once its read came back
  conclusively. That is a ledger, none, or one of another format (start fresh). Thread unreachable, or a ledger of
  this format that does not decode, blocks the write until a later read succeeds.
- **It stays under AII's 1 MB envelope.** Past 900 KB, the rows seen longest ago go, and their readings are
  forgotten with them, so the ledger and AII still agree.

**Retention** (Settings › Reading: forever, or 30, 90, 180 or 365 days) lets go of readings not seen within the
window: their documents, one remove each, then the rows. Turns and remarks do not age.

## 6. Rao Verified

Every deposit carries a Rao Verified record in its envelope's `verified` (Ambient's `AmbientThread/README.md`).

| Deposit | Origin | Covered |
| --- | --- | --- |
| A reading | `read` | its passages |
| A typed or spoken turn | `written` or `spoken` | the person's words, by byte offset inside the one partition |
| Her remarks | `generated` | nothing |
| The ledger | `system` | nothing |
| A Link note | `imported` | nothing |

How a page was read (`via`) and whether its tree had to be woken (`woken`) are measurements in that record, not
fields of the reading.

## 7. Claiming

With nobody signed in, Ambient files under `aii-local`. At the next sign-in, if the person says yes, each reading,
turn and remark is filed again under the account. Each move keeps its words byte for byte, takes the account's own
id, and has its record re-sealed for the account. It is read back, and only then is the `aii-local` copy removed.
The `aii-local` ledger's rows merge into the account's ledger, and that ledger is removed once nothing is left to
claim. Sewn's memory stays where it is. An iPhone's notes are filed for the account from the iPhone itself.

## 8. Local only, and why

| What | Where | Why it is not in AII |
| --- | --- | --- |
| Settings | `~/Library/Application Support/nyc.rao.ambient/granite-db/ambient.persistence.config.0001` | this Mac's choices |
| The chat page | `~/Library/Application Support/nyc.rao.ambient/granite-db/ambient.persistence.chat.0001` | what the window shows now; what was said is in AII |
| The iPhone notes ledger | `~/Library/Application Support/Ambient/companion/notes.json` | a list of hashes per iPhone, `link-note/1`; nothing to recall |
| Keys and the session | the Keychain: `nyc.rao.ambient.provider-keys`, `nyc.rao.ambient.account`, `nyc.rao.ambient.link`, `nyc.rao.verified` | secrets never enter an index |
| The stack secret | `~/.rao/secrets/ambient` | AII's own contract |
| Held while running | `UnitIndexLedger`, `RetrievalTraceLedger`, `AttentionLedger`, `ReadingCoverageLedger`, `ReadDeliveryLedger` | the debugger's and the attention ring's: gone at quit |

## 9. Starting fresh

Settings › Servers › Rebuild index empties Ambient's lane: every document of every owner, Sewn's memory of Ambient's
conversations with it (`ThreadGraphAdmin.clearNode`, `POST /v1/clear` with Ambient's secret). Other lanes are
untouched, and so is Link. "Clear what Ambient read" lets go of Ambient's three groups for the signed-in owner and
leaves Sewn's memory and Link. Nothing older than these formats is read or translated: a record of another format
is left alone.
