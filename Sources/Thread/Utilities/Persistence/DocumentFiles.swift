//
//  DocumentFiles.swift
//  Thread
//
//  Created by Ritesh Pakala on 11/16/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Where a document's two files live under the storage root: `documents/<shard>/<id>` (the
//        document) and `documents/<shard>/<id>-parts` (its partitions' data), and how files
//        filed flat (every document in one `documents/` folder) reach that layout.
//  PIN:  SHARDED BY A STABLE HASH. The shard is two hex digits of the id's FNV-1a hash: 256
//        folders, the same for an id in every process and every build (never Swift's `Hasher`,
//        which is seeded per process). A folder of every document makes each name the file system
//        does not hold cost a scan of the whole folder on a disk whose folders are unindexed
//        (exFAT): a save's temporary name, a missing file at start-up. 256 folders keep each one
//        small on any disk.
//  PIN:  A FLAT FOLDER IS SET ASIDE WITH ONE RENAME AND NEVER LISTED OR CHANGED AGAIN. On
//        exFAT through macOS's FSKit driver a folder of ~230k entries takes over ten minutes to
//        list and ~10 s to change (every move, delete or new name rewrites it), while a file in
//        it read by its name opens in milliseconds. So `setFlatAside` renames a flat
//        `documents/` to `documents-flat/` and starts a fresh `documents/`, and a file is copied
//        out by name the first time it is missed in its shard: the registry's documents at
//        start-up (`adopt`, in parallel), a parts file when a search first needs it. Nothing
//        is deleted from `documents-flat/` (each delete would cost a rewrite of it); once every
//        node on the data directory has started, the folder holds only copies and stale files
//        and can be removed whole.
//

import Foundation
import Logging

enum DocumentFiles {
    static let folder = "documents"
    static let flatFolder = "documents-flat"
    static let partsSuffix = "-parts"

    /// The id's folder under `documents/`: two hex digits of its FNV-1a hash.
    static func shard(_ id: DocumentID) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in id.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        let low = hash & 0xff
        let digits = Array("0123456789abcdef")
        return String([digits[Int(low >> 4)], digits[Int(low & 0xf)]])
    }

    /// The document's file key.
    static func documentKey(_ id: DocumentID) -> String { "\(folder)/\(shard(id))/\(id)" }

    /// The key of the file holding the document's partitions' data.
    static func partsKey(_ id: DocumentID) -> String { "\(folder)/\(shard(id))/\(id)\(partsSuffix)" }

    /// Renames a flat `documents/` under `root` to `documents-flat/` and starts an empty
    /// `documents/`: two operations, whatever the folder holds. A no-op when `documents/` holds
    /// only shard folders or a flat folder is already aside.
    static func setFlatAside(root: URL, logger: Logger) {
        let fm = FileManager.default
        let documents = root.appendingPathComponent(folder, isDirectory: true)
        let flat = root.appendingPathComponent(flatFolder, isDirectory: true)
        guard isFlat(documents) else { return }
        guard !fm.fileExists(atPath: flat.path(percentEncoded: false)) else {
            logger.warning("documents: files at the top of documents/ while \(flatFolder)/ is aside; they are not read")
            return
        }
        do {
            try fm.moveItem(at: documents, to: flat)
            try fm.createDirectory(at: documents, withIntermediateDirectories: true)
            logger.info("documents: a flat folder set aside as \(flatFolder)/; its files are copied into shards by name as they are needed")
        } catch {
            logger.error("documents: could not set the flat folder aside: \(error.localizedDescription)")
        }
    }

    enum Adoption: Equatable {
        /// Copied from `documents-flat/` into its shard.
        case copied
        /// Not in `documents-flat/` (or no flat folder is aside).
        case absent
        /// There, but it could not be copied; it stays where it is.
        case failed
    }

    /// Flat files asked for and not there, by path: a name missing from a folder of ~230k
    /// entries costs seconds to look up on exFAT, so each is asked once per process.
    private static let knownAbsent = LockedValue<Set<String>>([])

    /// Copies `key` (a `documentKey` or `partsKey`) from `documents-flat/` under `root` into its
    /// shard, reading the flat file by its name only. Call it after the shard missed: the flat
    /// folder is asked only for files the shards do not hold.
    static func adopt(_ key: String, root: URL, logger: Logger) -> Adoption {
        let fm = FileManager.default
        let flat = root.appendingPathComponent(flatFolder, isDirectory: true)
        guard fm.fileExists(atPath: flat.path(percentEncoded: false)) else { return .absent }
        // "documents/<shard>/<relative>" → "<relative>", the file's path in the flat folder.
        let relative = key.split(separator: "/", maxSplits: 2).dropFirst(2).first.map(String.init) ?? key
        let source = flat.appendingPathComponent(relative, isDirectory: false)
        let sourcePath = source.path(percentEncoded: false)
        if knownAbsent.withLock({ $0.contains(sourcePath) }) { return .absent }
        let data: Data
        do {
            data = try Data(contentsOf: source)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            knownAbsent.withLock { _ = $0.insert(sourcePath) }
            return .absent
        } catch {
            logger.error("documents: could not read \(relative) from \(flatFolder)/: \(error.localizedDescription)")
            return .failed
        }
        let destination = root.appendingPathComponent(key, isDirectory: false)
        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            // PIN: A PLAIN WRITE, NOT AN ATOMIC ONE. An atomic write's fsync and rename cost
            // ~1.2 s a file on exFAT through FSKit against ~80 ms plain; a copy a stop cuts short
            // fails to decode, so the next start misses it in its shard and copies it again.
            try data.write(to: destination)
            return .copied
        } catch {
            logger.error("documents: could not copy \(relative) into its shard: \(error.localizedDescription)")
            return .failed
        }
    }

    /// Whether `documents/` holds anything but shard folders: a file at its top, or a folder whose
    /// name is not two hex digits (an id with a slash in it, filed flat). Reads the listing only
    /// until the first such entry.
    static func isFlat(_ documents: URL) -> Bool {
        guard let entries = FileManager.default.enumerator(
            at: documents, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsSubdirectoryDescendants]) else { return false }
        for case let entry as URL in entries {
            let name = entry.lastPathComponent
            if name.hasPrefix("._") || name == ".DS_Store" { continue }
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !isDirectory || !isShardName(name) { return true }
        }
        return false
    }

    static func isShardName(_ name: String) -> Bool {
        name.count == 2 && name.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
