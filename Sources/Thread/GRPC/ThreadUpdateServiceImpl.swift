//
//  ThreadUpdateServiceImpl.swift
//  Thread
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//

import AII
import Seam
import Foundation
import GRPCCore
import GRPCProtobuf

/// Served through the mothership session dispatcher and, directly, on the
/// node's gRPC port — a direct client can rename a group, change access or read
/// stats without a Sewn hop.
final class ThreadUpdateServiceImpl: Thread_V1_ThreadUpdate.ServiceProtocol, Sendable {
    let database: Database
    let resolver: LaneResolver

    init(database: Database, resolver: LaneResolver = .unscoped) {
        self.database = database
        self.resolver = resolver
    }

    // MARK: - Direct port (ServiceProtocol)

    func updateGroup(
        request: GRPCCore.ServerRequest<Thread_V1_ThreadUpdateGroupRequest>,
        context: GRPCCore.ServerContext
    ) async throws -> GRPCCore.ServerResponse<Thread_V1_ThreadUpdateGroupResponse> {
        ServerResponse(message: try await updateGroup(request.message, caller: .metadata(request.metadata)))
    }

    func updateDocument(
        request: GRPCCore.ServerRequest<Thread_V1_ThreadUpdateDocumentRequest>,
        context: GRPCCore.ServerContext
    ) async throws -> GRPCCore.ServerResponse<Thread_V1_ThreadUpdateDocumentResponse> {
        ServerResponse(message: try await updateDocument(request.message, caller: .metadata(request.metadata)))
    }

    func stats(
        request: GRPCCore.ServerRequest<Thread_V1_ThreadStatsRequest>,
        context: GRPCCore.ServerContext
    ) async throws -> GRPCCore.ServerResponse<Thread_V1_ThreadStatsResponse> {
        ServerResponse(message: try await stats(request.message, caller: .metadata(request.metadata)))
    }

    func removeGroups(
        request: GRPCCore.ServerRequest<Thread_V1_ThreadRemoveGroupsRequest>,
        context: GRPCCore.ServerContext
    ) async throws -> GRPCCore.ServerResponse<Thread_V1_ThreadRemoveGroupsResponse> {
        ServerResponse(message: try await removeGroups(request.message, caller: .metadata(request.metadata)))
    }

    // MARK: - UpdateGroup

    func updateGroup(
        _ request: Thread_V1_ThreadUpdateGroupRequest,
        caller: LaneCaller
    ) async throws -> Thread_V1_ThreadUpdateGroupResponse {
        let lane = try resolver.writeLane(try resolver.scope(for: caller))
        let ownerId = request.ownerID
        let groupId = request.groupID
        var didUpdate = false

        if !request.access.isEmpty,
           let access = ThreadRegistry.Access(rawValue: request.access) {
            let ok = await database.updateGroupAccess(groupId, ownerId: ownerId, access: access, lane: lane)
            didUpdate = didUpdate || ok
        }

        if !request.label.isEmpty {
            let ok = await database.renameGroup(id: groupId, ownerId: ownerId, label: request.label, lane: lane)
            didUpdate = didUpdate || ok
        }

        if request.updateMetadata {
            let meta = Database.Group.Metadata(
                description: request.groupDescription.isEmpty ? nil : request.groupDescription,
                tags: Array(request.tags)
            )
            let ok = await database.updateGroupMetadata(id: groupId, ownerId: ownerId, metadata: meta, lane: lane)
            didUpdate = didUpdate || ok
        }

        var response = Thread_V1_ThreadUpdateGroupResponse()
        response.success = didUpdate
        response.groupID = groupId
        return response
    }

    // MARK: - RemoveGroups

    /// Deletes groups the caller owns in its lane, and what is filed in them
    /// (`Database.removeGroups`).
    ///
    /// PIN: direct only. The Session stream has no arm for it, so Sewn cannot fan a group
    /// delete out across nodes; the lane is the one the caller's own secret resolves to,
    /// never one stamped on its behalf — a trusted caller is refused here as well, should
    /// an arm ever be added.
    func removeGroups(
        _ request: Thread_V1_ThreadRemoveGroupsRequest,
        caller: LaneCaller
    ) async throws -> Thread_V1_ThreadRemoveGroupsResponse {
        if case .trusted = caller {
            throw RPCError(code: .permissionDenied, message: "RemoveGroups is direct only: call the node, not the Session stream")
        }
        let lane = try resolver.writeLane(try resolver.scope(for: caller))
        var response = Thread_V1_ThreadRemoveGroupsResponse()
        response.success = true
        guard !request.groupIds.isEmpty else { return response }
        let removal = await database.removeGroups(request.groupIds, ownerId: request.ownerID, lane: lane)
        response.removedGroupIds = removal.groups
        response.removedDocumentCount = Int32(removal.unlinked.count)
        return response
    }

    // MARK: - UpdateDocument

    func updateDocument(
        _ request: Thread_V1_ThreadUpdateDocumentRequest,
        caller: LaneCaller
    ) async throws -> Thread_V1_ThreadUpdateDocumentResponse {
        let lane = try resolver.writeLane(try resolver.scope(for: caller))
        let ownerId = request.ownerID
        let documentId = request.documentID
        var didUpdate = false

        if !request.access.isEmpty,
           let access = ThreadRegistry.Access(rawValue: request.access) {
            let ok = await database.updateDocumentAccess(documentId, ownerId: ownerId, access: access, lane: lane)
            didUpdate = didUpdate || ok
        }

        if !request.groupID.isEmpty {
            let group = database.groups(for: ownerId, lane: lane).first { $0.id == request.groupID }
            if let group {
                let ok = await database.updateGroup(group, documentId: documentId, ownerId: ownerId, lane: lane)
                didUpdate = didUpdate || ok
            }
        }

        var response = Thread_V1_ThreadUpdateDocumentResponse()
        response.success = didUpdate
        response.documentID = documentId
        return response
    }

    // MARK: - Stats

    /// The caller's lane's counts; the whole node's for the stack identity or a Thread
    /// with no lanes, with every lane's counts (`lanes`) for the stack identity.
    func stats(
        _ request: Thread_V1_ThreadStatsRequest,
        caller: LaneCaller
    ) async throws -> Thread_V1_ThreadStatsResponse {
        let scope = try resolver.scope(for: caller)
        guard let registry = database.registry else {
            return Thread_V1_ThreadStatsResponse()
        }

        var response = Thread_V1_ThreadStatsResponse()
        if let lane = scope.filter {
            let own = database.stats(lane: lane)
            response.documentCount = Int64(own.documents)
            response.groupCount = Int64(own.groups)
            response.ownerCount = Int64(own.owners)
            let laneDocuments = registry.documents(inLane: lane) ?? []
            response.availableDocumentCount = Int64(registry.availableDocumentIds.intersection(laneDocuments).count)
        } else {
            response.documentCount = Int64(registry.documentOwners.count)
            response.groupCount = Int64(registry.groups.count)
            response.ownerCount = Int64(registry.ownersDocuments.count)
            response.availableDocumentCount = Int64(registry.availableDocumentIds.count)
        }
        if case .all = scope {
            response.lanes = database.statsByLane().values
                .sorted { $0.lane.rawValue < $1.lane.rawValue }
                .map(ThreadGraphServiceImpl.laneStats)
        }
        return response
    }
}
