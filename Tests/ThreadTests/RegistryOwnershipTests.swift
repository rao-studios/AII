//
//  RegistryOwnershipTests.swift
//  ThreadTests
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  Tests covering ownership ID case normalization and registry integrity for
//  remove / modify operations.
//
//  Why these tests exist:
//    UUID.uuidString returns uppercase on all Swift platforms, but Supabase
//    auth.uid() is always lowercase. Without normalization at the request
//    boundary, registry ownership checks silently fail for any user whose ID
//    was stored in a different case.
//
//    DatabaseRequest.from(_:) lowercases the ownerId at the entry point so all
//    registry keys are consistently lowercase. These tests pin that behaviour
//    and the group lifecycle: a group exists while it holds documents — an
//    owner's removal or move drops a group it leaves empty (never another
//    owner's), crash recovery keeps groups for the re-index, and removeGroups
//    deletes one outright, empty or not.
//

import XCTest
@testable import Thread

final class RegistryOwnershipTests: XCTestCase {

    // MARK: - Helpers

    private func registryWithDocument(
        documentId: String,
        ownerId: String,
        groupId: String? = nil
    ) -> ThreadRegistry {
        var registry = ThreadRegistry()
        let owner = ThreadRegistry.Owner(id: ownerId)

        registry.documentOwners[documentId] = [owner]
        var ownerDocs = registry.ownersDocuments[owner] ?? []
        ownerDocs.append(documentId)
        registry.ownersDocuments[owner] = ownerDocs
        registry.documentAccess[documentId] = .restricted

        if let groupId {
            registry.documentGroups[documentId] = [groupId]
            registry.ownerDocumentGroup[ownerId] = [documentId: groupId]
            registry.groupOwners[groupId] = owner
            registry.groupAccess[groupId] = .restricted
            registry.groups[groupId] = [documentId]

            var ownerGroups = registry.ownersGroups[owner] ?? []
            ownerGroups.append(
                .init(id: groupId, label: "Test Group", ownerId: ownerId, documents: [])
            )
            registry.ownersGroups[owner] = ownerGroups
        }

        return registry
    }

    // MARK: - Case Normalization

    func testMutatorRemoveFailsWhenOwnerIdCaseMismatches() async {
        let mutator = RegistryMutator.test()
        let doc = Database.Document.test(id: "doc-case", ownerId: "aabbccdd-0000-0000-0000-000000000001")
        await mutator.register(doc, group: nil, ownerId: "aabbccdd-0000-0000-0000-000000000001")

        let result = await mutator.remove(
            documentId: "doc-case",
            group: nil,
            ownerId: "AABBCCDD-0000-0000-0000-000000000001"
        )

        XCTAssertFalse(result.authorized, "remove must reject a caller whose ownerId differs only in case")
        let snapshot = mutator.snapshot ?? ThreadRegistry()
        XCTAssertNotNil(snapshot.documentOwners["doc-case"],
            "document must still be present after rejected removal")
    }

    func testMutatorRemoveSucceedsWithMatchingLowercaseOwnerId() async {
        let mutator = RegistryMutator.test()
        let ownerId = "aabbccdd-0000-0000-0000-000000000001"
        let doc = Database.Document.test(id: "doc-lower", ownerId: ownerId)
        await mutator.register(doc, group: nil, ownerId: ownerId)

        let result = await mutator.remove(documentId: "doc-lower", group: nil, ownerId: ownerId)

        XCTAssertTrue(result.authorized)
        XCTAssertTrue(result.fullyRemoved, "sole owner removal must fully remove the document")
        let snapshot = mutator.snapshot ?? ThreadRegistry()
        XCTAssertNil(snapshot.documentOwners["doc-lower"], "documentOwners must be cleared")
        XCTAssertNil(snapshot.documentAccess["doc-lower"], "documentAccess must be cleared")
    }

    // MARK: - Empty Group Cleanup on Remove

    func testRemoveLastDocumentDropsTheGroup() {
        let ownerId = "owner-a"
        var registry = registryWithDocument(
            documentId: "doc-1",
            ownerId: ownerId,
            groupId: "group-x"
        )
        let owner = ThreadRegistry.Owner(id: ownerId)

        registry.remove(documentId: "doc-1", group: nil, owner: owner)

        XCTAssertNil(registry.groups["group-x"],
            "a group exists while it holds documents: the last one out takes it")
        XCTAssertNil(registry.groupOwners["group-x"], "groupOwners must be cleared with the group")
        XCTAssertNil(registry.groupAccess["group-x"], "groupAccess must be cleared with the group")
        XCTAssertFalse(
            registry.ownersGroups[owner]?.contains(where: { $0.id == "group-x" }) ?? false,
            "ownersGroups must no longer list the group"
        )
    }

    func testRemoveNonLastDocumentInGroupLeavesGroupIntact() {
        var registry = registryWithDocument(
            documentId: "doc-1",
            ownerId: "owner-a",
            groupId: "group-x"
        )
        let owner = ThreadRegistry.Owner(id: "owner-a")
        registry.documentOwners["doc-2"] = [owner]
        registry.documentGroups["doc-2"] = ["group-x"]
        registry.documentAccess["doc-2"] = .restricted
        var ownerDocs = registry.ownersDocuments[owner] ?? []
        ownerDocs.append("doc-2")
        registry.ownersDocuments[owner] = ownerDocs
        registry.groups["group-x"]?.append("doc-2")

        registry.remove(documentId: "doc-1", group: nil, owner: owner)

        XCTAssertNotNil(registry.groups["group-x"],
            "group must survive when it still has remaining documents")
        XCTAssertEqual(registry.groups["group-x"], ["doc-2"],
            "only the removed document must be absent from groups[groupId]")
        XCTAssertNotNil(registry.groupOwners["group-x"],
            "groupOwners must be preserved for a non-empty group")
        XCTAssertNotNil(registry.groupAccess["group-x"],
            "groupAccess must be preserved for a non-empty group")
    }

    func testRemoveWithoutTheGroupStillDropsTheGroupItEmpties() {
        let ownerId = "owner-b"
        var registry = registryWithDocument(
            documentId: "doc-3",
            ownerId: ownerId,
            groupId: "group-y"
        )
        let owner = ThreadRegistry.Owner(id: ownerId)

        let fullyRemoved = registry.remove(documentId: "doc-3", group: nil, owner: owner)

        XCTAssertTrue(fullyRemoved, "sole owner removal must be a full removal")
        XCTAssertNil(registry.documentOwners["doc-3"], "document must be removed")
        XCTAssertNil(registry.groups["group-y"],
            "the group goes with its last document even when the remove does not name it")
        XCTAssertNil(registry.groupOwners["group-y"])
    }

    /// A co-owner's remove touches its own groups only: the old fallback read the document's
    /// first group whoever owned it, and stripped the other owner's group.
    func testACoOwnersRemoveNeverEmptiesTheOtherOwnersGroup() {
        var registry = registryWithDocument(documentId: "doc-1", ownerId: "owner-a", groupId: "group-a")
        let ownerB = ThreadRegistry.Owner(id: "owner-b")
        registry.documentOwners["doc-1"]?.insert(ownerB)
        registry.ownersDocuments[ownerB] = ["doc-1"]

        let fullyRemoved = registry.remove(documentId: "doc-1", group: nil, owner: ownerB)

        XCTAssertFalse(fullyRemoved, "owner-a still holds the document")
        XCTAssertEqual(registry.groups["group-a"], ["doc-1"], "owner-a's group keeps the document")
        XCTAssertEqual(registry.documentGroups["doc-1"], ["group-a"])
        XCTAssertNotNil(registry.groupOwners["group-a"])
        XCTAssertEqual(registry.documentOwners["doc-1"], [ThreadRegistry.Owner(id: "owner-a")])
    }

    /// The same owner filed one document under two groups: removing it takes it out of both,
    /// and each group it empties goes.
    func testRemoveTakesTheDocumentOutOfEveryGroupOfTheOwners() {
        var registry = registryWithDocument(documentId: "doc-1", ownerId: "owner-a", groupId: "group-1")
        let owner = ThreadRegistry.Owner(id: "owner-a")
        registry.documentGroups["doc-1"]?.insert("group-2")
        registry.groupOwners["group-2"] = owner
        registry.groupAccess["group-2"] = .restricted
        registry.groups["group-2"] = ["doc-1"]
        registry.ownersGroups[owner]?.append(.init(id: "group-2", label: "Second", ownerId: "owner-a", documents: []))

        registry.remove(documentId: "doc-1", group: nil, owner: owner)

        XCTAssertNil(registry.groupOwners["group-1"])
        XCTAssertNil(registry.groupOwners["group-2"], "the second group held nothing else and went too")
        XCTAssertNil(registry.documentGroups["doc-1"])
        XCTAssertTrue((registry.ownersGroups[owner] ?? []).isEmpty)
    }

    /// Crash recovery drops what a crash left half-written and keeps its groups: the
    /// re-index files the documents back into them, label and access intact.
    func testTheOrphanSweepKeepsTheGroupsItEmpties() {
        var registry = registryWithDocument(documentId: "doc-1", ownerId: "owner-a", groupId: "group-x")

        registry.removeOrphaned(documentId: "doc-1")

        XCTAssertEqual(registry.groups["group-x"], [], "the group waits for the re-index")
        XCTAssertNotNil(registry.groupOwners["group-x"])
        XCTAssertNotNil(registry.groupAccess["group-x"])
    }

    // MARK: - RegistryMutator: renameGroup ownership check

    func testRenameGroupRejectsNonOwner() async {
        let mutator = RegistryMutator.test()
        let doc = Database.Document.test(id: "doc-rename", ownerId: "real-owner")
        await mutator.register(doc, group: .test(id: "grp-1", ownerId: "real-owner"), ownerId: "real-owner")

        let renamed = await mutator.renameGroup(id: "grp-1", ownerId: "other-owner", label: "Hacked")

        XCTAssertFalse(renamed, "renameGroup must reject a caller who does not own the group")

        let snapshot = mutator.snapshot ?? ThreadRegistry()
        let owner = ThreadRegistry.Owner(id: "real-owner")
        let label = snapshot.ownersGroups[owner]?.first(where: { $0.id == "grp-1" })?.label
        XCTAssertEqual(label, "Test Group", "label must be unchanged after rejected rename")
    }

    func testRenameGroupSucceedsForOwner() async {
        let mutator = RegistryMutator.test()
        let doc = Database.Document.test(id: "doc-rename-ok", ownerId: "real-owner")
        await mutator.register(doc, group: .test(id: "grp-2", ownerId: "real-owner"), ownerId: "real-owner")

        let renamed = await mutator.renameGroup(id: "grp-2", ownerId: "real-owner", label: "New Name")

        XCTAssertTrue(renamed)
        let snapshot = mutator.snapshot ?? ThreadRegistry()
        let owner = ThreadRegistry.Owner(id: "real-owner")
        let label = snapshot.ownersGroups[owner]?.first(where: { $0.id == "grp-2" })?.label
        XCTAssertEqual(label, "New Name")
    }

    // MARK: - DocumentStats: seeding and removal

    func testDocumentStatsSeededOnRegister() async {
        let mutator = RegistryMutator.test()
        let doc     = Database.Document.test(id: "doc-stats-seed", ownerId: "owner-stats")
        await mutator.register(doc, group: nil, ownerId: "owner-stats")

        let snapshot = mutator.snapshot ?? ThreadRegistry()
        XCTAssertNotNil(snapshot.documentStats["doc-stats-seed"],
            "documentStats must contain an entry for the document after registration")
    }

    func testDocumentStatsZeroEarningsOnFirstRegister() async {
        let mutator = RegistryMutator.test()
        let doc     = Database.Document.test(id: "doc-stats-zero", ownerId: "owner-stats")
        await mutator.register(doc, group: nil, ownerId: "owner-stats")

        let snapshot = mutator.snapshot ?? ThreadRegistry()
        let stats    = snapshot.documentStats["doc-stats-zero"]
        XCTAssertEqual(stats?.totalEarned, 0,
            "totalEarned must be 0 immediately after registration")
    }

    func testDocumentStatsNotDuplicatedOnReRegister() async {
        let mutator = RegistryMutator.test()
        let doc     = Database.Document.test(id: "doc-stats-dup", ownerId: "owner-stats")
        await mutator.register(doc, group: nil, ownerId: "owner-stats")
        await mutator.accumulateEarnings(["doc-stats-dup": 5.0])
        await mutator.register(doc, group: nil, ownerId: "owner-stats")

        let snapshot = mutator.snapshot ?? ThreadRegistry()
        XCTAssertEqual(snapshot.documentStats["doc-stats-dup"]?.totalEarned, 5.0,
            "re-registering must not reset existing earnings")
    }

    func testDocumentStatsRemovedWhenDocumentIsRemoved() async {
        let mutator = RegistryMutator.test()
        let doc     = Database.Document.test(id: "doc-stats-del", ownerId: "owner-del")
        await mutator.register(doc, group: nil, ownerId: "owner-del")
        let result = await mutator.remove(documentId: "doc-stats-del", group: nil, ownerId: "owner-del")

        XCTAssertTrue(result.authorized)
        XCTAssertTrue(result.fullyRemoved)
        let snapshot = mutator.snapshot ?? ThreadRegistry()
        XCTAssertNil(snapshot.documentStats["doc-stats-del"],
            "documentStats must be cleared when the document is removed")
    }

    func testDocumentStatsRemovedViaRegistryRemoveOrphaned() {
        var registry = ThreadRegistry()
        let owner    = ThreadRegistry.Owner(id: "owner-orphan")
        registry.documentOwners["doc-orphan"]  = [owner]
        registry.documentAccess["doc-orphan"]  = .restricted
        registry.documentStats["doc-orphan"]   = .init(id: "doc-orphan", totalEarned: 3.5)

        registry.removeOrphaned(documentId: "doc-orphan")

        XCTAssertNil(registry.documentStats["doc-orphan"],
            "removeOrphaned must clean up documentStats")
    }

    func testDocumentStatsRemovedViaRegistryRemove() {
        var registry  = ThreadRegistry()
        let owner     = ThreadRegistry.Owner(id: "owner-rm")
        registry.documentOwners["doc-rm"] = [owner]
        registry.ownersDocuments[owner]   = ["doc-rm"]
        registry.documentAccess["doc-rm"] = .restricted
        registry.documentStats["doc-rm"]  = .init(id: "doc-rm", totalEarned: 1.0)

        registry.remove(documentId: "doc-rm", group: nil, owner: owner)

        XCTAssertNil(registry.documentStats["doc-rm"],
            "registry.remove must delete the documentStats entry")
    }

    // MARK: - DocumentStats: accumulation

    func testAccumulateEarningsUpdatesStats() async {
        let mutator = RegistryMutator.test()
        let doc     = Database.Document.test(id: "doc-earn-1", ownerId: "owner-earn")
        await mutator.register(doc, group: nil, ownerId: "owner-earn")
        await mutator.accumulateEarnings(["doc-earn-1": 2.5])

        let snapshot = mutator.snapshot ?? ThreadRegistry()
        XCTAssertEqual(snapshot.documentStats["doc-earn-1"]?.totalEarned ?? -1, 2.5, accuracy: 1e-9)
    }

    func testAccumulateEarningsIsAdditive() async {
        let mutator = RegistryMutator.test()
        let doc     = Database.Document.test(id: "doc-earn-add", ownerId: "owner-earn")
        await mutator.register(doc, group: nil, ownerId: "owner-earn")
        await mutator.accumulateEarnings(["doc-earn-add": 1.0])
        await mutator.accumulateEarnings(["doc-earn-add": 2.0])

        let snapshot = mutator.snapshot ?? ThreadRegistry()
        XCTAssertEqual(snapshot.documentStats["doc-earn-add"]?.totalEarned ?? -1, 3.0, accuracy: 1e-9,
            "accumulateEarnings must add to the existing totalEarned, not replace it")
    }

    func testAccumulateEarningsIgnoresZeroCredits() async {
        let mutator = RegistryMutator.test()
        let doc     = Database.Document.test(id: "doc-earn-zero", ownerId: "owner-earn")
        await mutator.register(doc, group: nil, ownerId: "owner-earn")
        await mutator.accumulateEarnings(["doc-earn-zero": 0.0])

        let snapshot = mutator.snapshot ?? ThreadRegistry()
        XCTAssertEqual(snapshot.documentStats["doc-earn-zero"]?.totalEarned ?? 0, 0,
            "zero-credit accumulation must not change totalEarned")
    }

    func testAccumulateEarningsCreatesEntryForUnregisteredDocument() async {
        let mutator = RegistryMutator.test()
        await mutator.accumulateEarnings(["doc-unregistered": 7.0])

        let snapshot = mutator.snapshot ?? ThreadRegistry()
        XCTAssertEqual(snapshot.documentStats["doc-unregistered"]?.totalEarned ?? -1, 7.0, accuracy: 1e-9,
            "accumulateEarnings must create a stats entry even if the document was not registered")
    }

    func testAccumulateEarningsMultipleDocumentsInOneCall() async {
        let mutator = RegistryMutator.test()
        await mutator.accumulateEarnings(["doc-multi-a": 3.0, "doc-multi-b": 1.5, "doc-multi-c": 0.75])

        let snapshot = mutator.snapshot ?? ThreadRegistry()
        XCTAssertEqual(snapshot.documentStats["doc-multi-a"]?.totalEarned ?? -1, 3.0,   accuracy: 1e-9)
        XCTAssertEqual(snapshot.documentStats["doc-multi-b"]?.totalEarned ?? -1, 1.5,   accuracy: 1e-9)
        XCTAssertEqual(snapshot.documentStats["doc-multi-c"]?.totalEarned ?? -1, 0.75,  accuracy: 1e-9)
    }

    // MARK: - DocumentStats: group total earnings

    func testTotalEarningsForGroupSumsDocumentStats() {
        var registry = ThreadRegistry()
        registry.groups["grp-earn"] = ["doc-x", "doc-y", "doc-z"]
        registry.documentStats["doc-x"] = .init(id: "doc-x", totalEarned: 1.0)
        registry.documentStats["doc-y"] = .init(id: "doc-y", totalEarned: 2.5)
        registry.documentStats["doc-z"] = .init(id: "doc-z", totalEarned: 0.5)

        let total = registry.totalEarnings(for: "grp-earn")
        XCTAssertEqual(total, 4.0, accuracy: 1e-9,
            "totalEarnings must sum all document stats in the group")
    }

    func testTotalEarningsForGroupWithMissingStatsCountsAsZero() {
        var registry = ThreadRegistry()
        registry.groups["grp-partial"] = ["doc-has-stats", "doc-no-stats"]
        registry.documentStats["doc-has-stats"] = .init(id: "doc-has-stats", totalEarned: 3.0)

        let total = registry.totalEarnings(for: "grp-partial")
        XCTAssertEqual(total, 3.0, accuracy: 1e-9,
            "missing stats entry must count as 0, not crash")
    }

    func testTotalEarningsForUnknownGroupIsZero() {
        let registry = ThreadRegistry()
        XCTAssertEqual(registry.totalEarnings(for: "nonexistent-group"), 0,
            "unknown group must return 0 total earnings")
    }

    func testAddEarningsOnRegistryUpdatesExistingEntry() {
        var registry = ThreadRegistry()
        registry.documentStats["doc-add"] = .init(id: "doc-add", totalEarned: 2.0)

        registry.addEarnings(["doc-add": 1.5])

        XCTAssertEqual(registry.documentStats["doc-add"]?.totalEarned ?? -1, 3.5, accuracy: 1e-9)
    }

    func testAddEarningsOnRegistryCreatesNewEntry() {
        var registry = ThreadRegistry()
        registry.addEarnings(["doc-new": 4.0])

        XCTAssertNotNil(registry.documentStats["doc-new"])
        XCTAssertEqual(registry.documentStats["doc-new"]?.totalEarned ?? -1, 4.0, accuracy: 1e-9)
    }

    func testAddEarningsSkipsZeroValues() {
        var registry = ThreadRegistry()
        registry.addEarnings(["doc-skip": 0.0])
        XCTAssertEqual(registry.documentStats["doc-skip"]?.totalEarned ?? 0, 0)
    }

    // MARK: - RegistryMutator: updateGroup cleans up empty old group

    func testUpdateGroupDropsTheOldGroupItEmptied() async {
        let mutator = RegistryMutator.test()
        let ownerId = "owner-update"
        let doc = Database.Document.test(id: "doc-move", ownerId: ownerId)
        await mutator.register(doc, group: .test(id: "old-grp", ownerId: ownerId), ownerId: ownerId)

        let moved = await mutator.updateGroup(
            .test(id: "new-grp", ownerId: ownerId),
            documentId: "doc-move",
            ownerId: ownerId
        )
        XCTAssertTrue(moved)

        let snapshot = mutator.snapshot ?? ThreadRegistry()
        let owner = ThreadRegistry.Owner(id: ownerId)

        // The old group held only this document: it goes with it.
        XCTAssertNil(snapshot.groups["old-grp"], "the emptied old group must be dropped")
        XCTAssertNil(snapshot.groupOwners["old-grp"])
        XCTAssertNil(snapshot.groupAccess["old-grp"])
        XCTAssertFalse(
            snapshot.ownersGroups[owner]?.contains(where: { $0.id == "old-grp" }) ?? false,
            "ownersGroups must no longer list the old group"
        )
        XCTAssertTrue(
            snapshot.ownersGroups[owner]?.contains(where: { $0.id == "new-grp" }) ?? false,
            "the new group is listed"
        )

        // Document-level indices must point to the new group.
        XCTAssertTrue(
            snapshot.documentGroups["doc-move"]?.contains("new-grp") == true,
            "document must be recorded under new group in the Set index"
        )
        XCTAssertFalse(
            snapshot.documentGroups["doc-move"]?.contains("old-grp") == true,
            "old group must be absent from the document's group Set"
        )
        XCTAssertEqual(
            snapshot.ownerDocumentGroup[ownerId]?["doc-move"], "new-grp",
            "ownerDocumentGroup must reflect the new group for this owner"
        )
    }

    func testUpdateGroupKeepsAnOldGroupThatStillHoldsDocuments() async {
        let mutator = RegistryMutator.test()
        let ownerId = "owner-update"
        await mutator.register(.test(id: "doc-1", ownerId: ownerId), group: .test(id: "old-grp", ownerId: ownerId), ownerId: ownerId)
        await mutator.register(.test(id: "doc-2", ownerId: ownerId), group: .test(id: "old-grp", ownerId: ownerId), ownerId: ownerId)

        let moved = await mutator.updateGroup(.test(id: "new-grp", ownerId: ownerId), documentId: "doc-1", ownerId: ownerId)

        XCTAssertTrue(moved)
        let snapshot = mutator.snapshot ?? ThreadRegistry()
        XCTAssertEqual(snapshot.groups["old-grp"], ["doc-2"], "the old group still holds a document and stays")
        XCTAssertEqual(snapshot.groups["new-grp"], ["doc-1"])
    }

    // MARK: - removeBatch drops what it empties

    func testRemoveBatchDropsTheGroupsItEmpties() async {
        let mutator = RegistryMutator.test()
        let ownerId = "owner-a"
        await mutator.register(.test(id: "doc-1", ownerId: ownerId), group: .test(id: "grp-1", ownerId: ownerId), ownerId: ownerId)
        await mutator.register(.test(id: "doc-2", ownerId: ownerId), group: .test(id: "grp-2", ownerId: ownerId), ownerId: ownerId)
        await mutator.register(.test(id: "doc-3", ownerId: ownerId), group: .test(id: "grp-2", ownerId: ownerId), ownerId: ownerId)

        await mutator.removeBatch(items: [("doc-1", ownerId), ("doc-2", ownerId)])

        let snapshot = mutator.snapshot ?? ThreadRegistry()
        XCTAssertNil(snapshot.groupOwners["grp-1"], "grp-1 lost its only document and went")
        XCTAssertEqual(snapshot.groups["grp-2"], ["doc-3"], "grp-2 still holds doc-3")
    }

    // MARK: - removeGroups

    /// A group whose record outlived its documents — crash recovery, or a Thread from before
    /// empty groups were dropped — is deleted by id all the same.
    func testRemoveGroupsDeletesAGroupThatIsAlreadyEmpty() async {
        let owner = ThreadRegistry.Owner(id: "owner-a")
        var registry = registryWithDocument(documentId: "doc-1", ownerId: "owner-a", groupId: "grp-1")
        registry.removeOrphaned(documentId: "doc-1")
        let mutator = RegistryMutator.test()
        mutator.seed(registry)

        let removal = await mutator.removeGroups(["grp-1"], ownerId: "owner-a")

        XCTAssertEqual(removal.groups, ["grp-1"])
        XCTAssertEqual(removal.unlinked, [])
        let snapshot = mutator.snapshot ?? ThreadRegistry()
        XCTAssertNil(snapshot.groups["grp-1"])
        XCTAssertNil(snapshot.groupOwners["grp-1"])
        XCTAssertNil(snapshot.groupAccess["grp-1"])
        XCTAssertFalse(snapshot.ownersGroups[owner]?.contains(where: { $0.id == "grp-1" }) ?? false)
    }

    func testRemoveGroupsUnlinksACoOwnedDocumentAndPurgesASoleOwnedOne() async {
        let mutator = RegistryMutator.test()
        await mutator.register(.test(id: "doc-1", ownerId: "owner-a"), group: .test(id: "grp-a", ownerId: "owner-a"), ownerId: "owner-a")
        await mutator.register(.test(id: "doc-2", ownerId: "owner-a"), group: .test(id: "grp-a", ownerId: "owner-a"), ownerId: "owner-a")
        await mutator.linkOwner(documentId: "doc-2", group: .test(id: "grp-b", ownerId: "owner-b"), ownerId: "owner-b")

        let removal = await mutator.removeGroups(["grp-a"], ownerId: "owner-a")

        XCTAssertEqual(removal.groups, ["grp-a"])
        XCTAssertEqual(Set(removal.unlinked), ["doc-1", "doc-2"])
        XCTAssertEqual(removal.fullyRemoved, ["doc-1"], "only doc-1 had no other owner")
        let snapshot = mutator.snapshot ?? ThreadRegistry()
        XCTAssertNil(snapshot.groupOwners["grp-a"])
        XCTAssertNil(snapshot.documentOwners["doc-1"])
        XCTAssertEqual(snapshot.documentOwners["doc-2"], [ThreadRegistry.Owner(id: "owner-b")])
        XCTAssertEqual(snapshot.groups["grp-b"], ["doc-2"], "owner-b's group keeps its document")
    }

    /// Filed by the same owner under two groups, a document stays in the one not deleted —
    /// and the owner's place for it moves there.
    func testRemoveGroupsLeavesADocumentTheOwnerAlsoFiledElsewhere() async {
        let owner = ThreadRegistry.Owner(id: "owner-a")
        let mutator = RegistryMutator.test()
        let doc = Database.Document.test(id: "doc-1", ownerId: "owner-a")
        await mutator.register(doc, group: .test(id: "grp-1", ownerId: "owner-a"), ownerId: "owner-a")
        await mutator.register(doc, group: .test(id: "grp-2", ownerId: "owner-a"), ownerId: "owner-a")
        XCTAssertEqual(mutator.snapshot?.ownerDocumentGroup["owner-a"]?["doc-1"], "grp-2", "precondition: the later filing is its place")

        let removal = await mutator.removeGroups(["grp-2"], ownerId: "owner-a")

        XCTAssertEqual(removal.groups, ["grp-2"])
        XCTAssertEqual(removal.unlinked, [], "the owner still holds it")
        let snapshot = mutator.snapshot ?? ThreadRegistry()
        XCTAssertEqual(snapshot.documentOwners["doc-1"], [owner])
        XCTAssertEqual(snapshot.groups["grp-1"], ["doc-1"])
        XCTAssertEqual(snapshot.documentGroups["doc-1"], ["grp-1"])
        XCTAssertEqual(snapshot.ownerDocumentGroup["owner-a"]?["doc-1"], "grp-1")
        XCTAssertNil(snapshot.groupOwners["grp-2"])
    }

    func testRemoveGroupsRefusesAnotherOwnersGroup() async {
        let mutator = RegistryMutator.test()
        await mutator.register(
            .test(id: "doc-1", ownerId: "owner-a"),
            group: .test(id: "grp-a", ownerId: "owner-a"),
            ownerId: "owner-a"
        )

        // owner-b attempts to delete owner-a's group.
        let removal = await mutator.removeGroups(["grp-a"], ownerId: "owner-b")

        XCTAssertEqual(removal, Database.GroupRemoval())
        let snapshot = mutator.snapshot ?? ThreadRegistry()
        XCTAssertNotNil(snapshot.groupOwners["grp-a"],
            "groupOwners must not be cleared when the caller does not own the group")
        XCTAssertEqual(snapshot.groups["grp-a"], ["doc-1"], "the group and its document survive")
        XCTAssertNotNil(snapshot.documentOwners["doc-1"])
    }

    func testRemoveGroupsRefusesAnotherLanesGroup() async {
        let mutator = RegistryMutator.test()
        await mutator.register(.test(id: "doc-1", ownerId: "owner-a"), group: .test(id: "grp-a", ownerId: "owner-a"),
                               ownerId: "owner-a", lane: .a)

        let removal = await mutator.removeGroups(["grp-a"], ownerId: "owner-a", lane: .b)

        XCTAssertEqual(removal, Database.GroupRemoval())
        let snapshot = mutator.snapshot ?? ThreadRegistry()
        XCTAssertEqual(snapshot.groups["grp-a"], ["doc-1"], "lane b cannot delete lane a's group")
    }

    func testRemoveGroupsPreservesOtherOwnersGroups() async {
        let mutator = RegistryMutator.test()

        await mutator.register(
            .test(id: "doc-a", ownerId: "owner-a"),
            group: .test(id: "grp-a", ownerId: "owner-a"),
            ownerId: "owner-a"
        )
        await mutator.register(
            .test(id: "doc-b", ownerId: "owner-b"),
            group: .test(id: "grp-b", ownerId: "owner-b"),
            ownerId: "owner-b"
        )

        _ = await mutator.removeGroups(["grp-a", "grp-b"], ownerId: "owner-a")

        let snapshot = mutator.snapshot ?? ThreadRegistry()
        XCTAssertNil(snapshot.groupOwners["grp-a"])
        XCTAssertNotNil(snapshot.groupOwners["grp-b"],
            "owner-b's group must be unaffected by owner-a's removeGroups call")
        XCTAssertEqual(snapshot.groups["grp-b"], ["doc-b"],
            "owner-b's document list must be unaffected")
    }
}
