//
//  DocumentFiles.swift
//  Thread
//
//  Created by Ritesh Pakala on 11/16/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Where a document's two files live under the storage root: `documents/<shard>/<id>` (the
//        document) and `documents/<shard>/<id>-parts` (its partitions' data), and the one-time move
//        of a flat `documents/` folder into that layout.
//  PIN:  SHARDED BY A STABLE HASH. The shard is two hex digits of the id's FNV-1a hash: 256
//        folders, the same for an id in every process and every build (never Swift's `Hasher`,
//        which is seeded per process). A folder of every document makes each name the file system
//        does not hold cost a scan of the whole folder on a disk whose folders are unindexed
//        (exFAT): a save's temporary name, a missing file at start-up. 256 folders keep each one
//        small on any disk.
//  PIN:  A FLAT FOLDER MOVES ONCE, INTO A FRESH ONE. `shardFlatLayout` renames a flat
//        `documents/` to `documents-flat/` and moves each file into a new `documents/`, because an
//        exFAT folder keeps its size after it is emptied. It runs before the registry loads, and a
//        move that stops resumes at the next start from `documents-flat/`.
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

    /// Moves a flat `documents/` under `root` into shards, once: a no-op when `documents/` holds
    /// only shard folders. Answers false while files are left in `documents-flat/` (a move that
    /// failed is kept there for the next start), so a caller drops nothing it could not find.
    @discardableResult
    static func shardFlatLayout(root: URL, logger: Logger) -> Bool {
        let fm = FileManager.default
        let documents = root.appendingPathComponent(folder, isDirectory: true)
        let flat = root.appendingPathComponent(flatFolder, isDirectory: true)
        let flatPath = flat.path(percentEncoded: false)

        if !fm.fileExists(atPath: flatPath) {
            guard isFlat(documents) else { return true }
            do {
                try fm.moveItem(at: documents, to: flat)
                try fm.createDirectory(at: documents, withIntermediateDirectories: true)
            } catch {
                logger.error("documents: could not set the flat folder aside to shard it: \(error.localizedDescription)")
                return false
            }
            logger.info("documents: moving a flat folder into shards")
        } else {
            logger.info("documents: resuming the move into shards")
        }

        let files = regularFiles(under: flat)
        var moved = 0
        var failed = 0
        var made = Set<String>()
        for relative in files {
            let source = flat.appendingPathComponent(relative, isDirectory: false)
            let name = (relative as NSString).lastPathComponent
            if name.contains(".sb-") {   // an atomic save that never renamed into place
                try? fm.removeItem(at: source)
                continue
            }
            let id = relative.hasSuffix(partsSuffix) ? String(relative.dropLast(partsSuffix.count)) : relative
            let destination = documents.appendingPathComponent(shard(id), isDirectory: true)
                .appendingPathComponent(relative, isDirectory: false)
            let parent = destination.deletingLastPathComponent()
            do {
                if made.insert(parent.path(percentEncoded: false)).inserted {
                    try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                }
                if fm.fileExists(atPath: destination.path(percentEncoded: false)) {
                    try fm.removeItem(at: source)   // moved before a stop; the shard holds it
                } else {
                    try fm.moveItem(at: source, to: destination)
                }
                moved += 1
                if moved % 10_000 == 0 { logger.info("documents: \(moved) of \(files.count) files in shards") }
            } catch {
                failed += 1
                logger.error("documents: could not move \(relative) into its shard: \(error.localizedDescription)")
            }
        }
        guard failed == 0 else {
            logger.error("documents: \(moved) file(s) moved into shards, \(failed) left in \(flatFolder)/ for the next start")
            return false
        }
        do {
            try fm.removeItem(at: flat)   // what is left: exFAT's ._ companions
        } catch {
            logger.error("documents: the emptied flat folder could not be removed: \(error.localizedDescription)")
        }
        logger.info("documents: \(moved) file(s) moved into shards")
        return true
    }

    /// Whether `documents/` holds anything but shard folders: a file at its top, or a folder whose
    /// name is not two hex digits (an id with a slash in it, filed flat).
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

    /// Every regular file under `folder`, as a path relative to it; exFAT's `._` companions left out.
    static func regularFiles(under folder: URL) -> [String] {
        let base = folder.standardizedFileURL.path(percentEncoded: false)
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard let entries = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: []) else { return [] }
        var files: [String] = []
        for case let entry as URL in entries {
            guard !entry.lastPathComponent.hasPrefix("._"),
                  (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let path = entry.standardizedFileURL.path(percentEncoded: false)
            if path.hasPrefix(prefix) { files.append(String(path.dropFirst(prefix.count))) }
        }
        return files
    }
}
