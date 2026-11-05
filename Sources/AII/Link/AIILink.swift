//
//  AIILink.swift
//  AII
//
//  Created by Ritesh Pakala on 11/05/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Link, AII's own lane: what a peripheral device — a phone today — sends
//        through a Mac app it is linked to as an accessory. Every app that accepts
//        links files here, in one place, so a note written on the phone is the
//        person's, not one app's. Its addresses and its credential.
//  IN:   An app that receives a linked device's notes (Ambient today, Craft later).
//  OUT:  The lane (`app`), the group a note is filed in, a note's ids, and the
//        credential that files into the lane.
//  PIN:  NO SECRET FILE. Link's credential is derived from this Mac's device key
//        (`keys/device.key`, which also keys the lane ids and Veil's tiles):
//        HMAC-SHA256(key, "rao-link-v1"), 64 hex. The servers' keyring derives the
//        same value, so nothing is written under secrets/ and nothing is rotated
//        apart from the key itself.
//  PIN:  SHARED READS, OWN WRITES. Every lane reads Link (`AIILanes.shared`); only
//        the Link credential writes it. An app's "clear everything" never takes a
//        linked device's notes with it.
//  PIN:  ONE GROUP PER OWNER: `link-<owner>`. A folder on the device is a field of
//        the note (`AIILinkNote.folder`), never a group: a group is a search scope.
//        Schemas/Link/ has the whole layout.
//

import Foundation

public enum AIILink {

    /// The lane.
    public static let app: AIIApp = .link

    /// The label Link's credential is derived under.
    public static let credentialLabel = "rao-link-v1"

    // MARK: - The credential

    /// Link's credential on the Mac `key` belongs to: 64 hex.
    public static func secret(deviceKey key: AIIDeviceKey) -> String {
        StackSecret.hex(key.mac(label: credentialLabel, message: Data()))
    }

    /// Link's credential on `home`'s Mac; nil until the device key exists.
    public static func secret(home: AIIHome) throws -> String? {
        try AIIDeviceKey.load(home: home).map { secret(deviceKey: $0) }
    }

    // MARK: - Where a note is filed

    /// The owner as Thread spells it: lowercased.
    public static func owner(_ ownerID: String) -> String { ownerID.lowercased() }

    /// The one group an owner's linked notes are filed in: `link-<owner>` on the wire.
    public static func group(ownerID: String) -> AIIRecord.Group {
        AIIRecord.Group(id: owner(ownerID), label: "Link")
    }

    /// `link-<owner>`.
    public static func groupID(ownerID: String) -> String {
        AIIRecord.groupID(app: app, group: group(ownerID: ownerID).id)
    }

    /// A note's id: 16 hex of FNV-1a over the owner and the note's own id. Keyed on the
    /// owner too, so the same note filed for another owner never shares an id (Thread
    /// keeps a document's files by id alone).
    public static func noteRecordID(noteID: String, ownerID: String) -> String {
        stableHash(owner(ownerID) + "|" + noteID.lowercased())
    }

    /// `link/note/<16 hex>`.
    public static func noteDocumentID(noteID: String, ownerID: String) -> String {
        AIIRecord.documentID(app: app, kind: AIILinkNote.kind, id: noteRecordID(noteID: noteID, ownerID: ownerID))
    }

    /// FNV-1a 64, 16 hex: the same on every Mac and every launch.
    static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}
