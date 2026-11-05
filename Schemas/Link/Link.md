# link-storage/1

What Link files into AII. **A link is a peripheral device, a phone today, connected to a Mac app as an accessory.**
What it sends belongs to the person, not to the app it was linked through. So Link is AII's own lane, `link`, which
every app on the Mac reads. Ambient files into it today, and Craft will later. This folder is AII's: the code in
`Sources/AII/Link/` generates the schema, and `Tests/AIITests/AIILinkTests.swift` holds both to it.

| File | What it describes |
| --- | --- |
| [`link-note.schema.json`](link-note.schema.json) | A note (`link-note/1`): the envelope's fields Link fixes and the payload (`AIILinkSchemaJSON.note`) |

## 1. The lane

| | |
| --- | --- |
| App | `link` (`AIIApp.link`), a lane in `aii/lanes.json` like any app's |
| Who files | The Mac app the device is linked to, with Link's credential |
| Who reads | Every lane (`AIILanes.shared`): an app's search, documents and library include Link's beside its own |
| Who removes | Link's credential only. An app's remove, its "clear everything" and its lane clear never reach Link's documents |
| Owner | The account, or `aii-local` with none, as the Rao apps file |

**The credential is derived, not kept.** Link has no file under `secrets/`. Its credential is
HMAC-SHA256(device key, `rao-link-v1`) as 64 hex, from this Mac's `keys/device.key`: the key the lane ids are derived
from and Veil's tiles are keyed with. The servers' keyring derives the same value (`StackKeyring`), so nothing new
is stored or rotated. `AIILink.secret(home:)` gives it to an app.

## 2. The group

One group per owner: `link-<owner>` on the wire (`AIILink.groupID`), labelled "Link". A group is a search scope, and
everything a linked device sends is searched together. A folder on the device is a field of the note, never a
group.

## 3. Kinds

| Kind | Document id | Format | Type |
| --- | --- | --- | --- |
| `note` | `link/note/<16 hex>`: FNV-1a of the owner, lowercased, then `\|` and the note's id, lowercased (`AIILink.noteDocumentID`) | `link-note/1` | `AIILinkNote` |

Anything else a linked device sends later is a new kind in the same lane and group, with its own schema here.

## 4. A note

An `aii-record/1` envelope, one per note and owner, replaced when the note changes. Keying on the owner means a note
filed for another owner never shares an id: Thread keeps a document's files by id alone.

**The envelope.**

| Field | Value |
| --- | --- |
| `app` | `link` |
| `kind` | `note` |
| `title` | the note's title, or its first 80 characters |
| `group` | `{id: <owner>, label: "Link"}` |
| `source` | `{kind: "link", ref: <note id>}` |
| `tags` | the note's tags, each a concept |
| `verified` | a Rao Verified record of origin `imported`: the Mac watched none of it written |

**The payload** (`link-note/1`):

| Key | What it holds |
| --- | --- |
| `format` | `link-note/1`. A reader that doesn't know the format leaves the note alone |
| `noteID` | the note's own id on the device, lowercased |
| `folder` | the device's folder for it, if any |
| `tags` | its tags, as written |
| `device` | `{kind, name, id}`; `kind` is `phone` today |
| `createdAt`, `updatedAt` | ISO-8601, to the second |
| `contentHash` | what the device says the words hash to |
| `characters` | the body's length |
| `filedBy` | the Mac app that received and filed it, e.g. `ambient` |

**The partitions.** The note's words, as written: nothing is summarized.

1. A card of facts, one per line: `Note: <title>`, `Written on: <device>`, `Written: <ISO-8601>`, then
   `Folder: <folder>` and `Tags: <a, b>` when there are any.
2. The body, its paragraphs packed into partitions of at most 1,200 characters. A long paragraph is cut after a
   sentence, else at a space. A note keeps at most 400 partitions.

`AIILinkNote` composes both, so every app files a note the same way.

## 5. Starting fresh

An app's lane clear leaves Link alone. To empty Link, its credential removes its documents: a remove with no ids,
under each owner.
