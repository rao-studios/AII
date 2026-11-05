# Schemas

What each app files into AII, one folder per app, and Link's, which is AII's own. AII's own contract is the envelope every document wears,
`aii-record/1`, and the lanes, owners and groups it is filed under:
[Docs/AII → The record](../Docs/AII/README.md#the-record) and [Protos → The record](../Protos/README.md#the-record).
An app's folder says what it puts inside that envelope: its groups, its kinds, its payloads and how it keys them.

| Folder | App | Lane | Written by |
| --- | --- | --- | --- |
| [`Craft/`](Craft/Storage.md) | Craft | `craft` | Craft's `scripts/schema/publish-aii.py`, from Craft's `Schema/` and `Docs/` |
| [`Link/`](Link/Link.md) | Link, every app's linked devices | `link`, shared | AII itself: `Sources/AII/Link/`, held by `Tests/AIITests/AIILinkTests.swift` |

An app's folder is a copy, published from the app's own repository, where its code generates the schemas and its
tests hold them to it. Edit it there and publish again; a change made here is replaced on the next publish. `Link/`
is the exception: it is AII's, generated and tested here (`AII_UPDATE_GOLDEN=1` rewrites its schema).

## Craft

Three groups, one a search scope each ([`Craft/Storage.md`](Craft/Storage.md) has the whole layout):

| Group | Holds | Read by | Schema |
| --- | --- | --- | --- |
| `craft-code-<scope>` | code cards, one document per file, one group per clone | code search | [`code-card.schema.json`](Craft/code-card.schema.json) |
| `craft-records` | `approach`, `lesson` and `note` records | search by meaning | [`craft-record.schema.json`](Craft/craft-record.schema.json) |
| `craft-index` | the `project` record, `instruction` records, the recall `ledger`, the `settings` | prefix, never searched | [`craft-index.schema.json`](Craft/craft-index.schema.json) |

`craft-index` is the project's bookkeeping, and nothing in it is found by meaning, so its schema says everything an
indexer needs to know a document by: the four kinds, each kind's envelope id and the entity it names, and each
payload — the records by `craft-record.schema.json`, the ledger (`craft-ledger/1`) and the settings
(`craft-settings/1`) in full.

## Link

A link is a peripheral device, a phone today, connected to a Mac app as an accessory. What it sends is the person's,
not the app's, so Link is AII's own lane, `link`. Every lane reads it beside its own; only Link's credential writes or
removes it. Link's credential is derived from the device key (`keys/device.key`), not kept in a file
([`Link/Link.md`](Link/Link.md) has the whole layout):

| Group | Holds | Read by | Schema |
| --- | --- | --- | --- |
| `link-<owner>` | `note` records, one per note and owner; the device's folder is a field | every lane, by meaning | [`link-note.schema.json`](Link/link-note.schema.json) |

The Mac app the device is linked to files a note with `AIILinkNote` (Ambient today, Craft later), so every app files
it the same way.
