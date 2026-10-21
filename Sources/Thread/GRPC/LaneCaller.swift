//
//  LaneCaller.swift
//  Thread
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Who is calling the one Thread, and which lane of the index that puts
//        them in. Every app shares this process; a lane is never trusted from a
//        client — it is derived from the secret that matched, or stamped by Sewn
//        on the session it opened to it.
//  IN:   Direct gRPC (the request's metadata), the mothership session (the
//        `lane` field Sewn set), HTTP (the identity StackSecretMiddleware admitted).
//  OUT:  A LaneScope: one lane, or every lane for the stack identity (`aii`).
//  PIN:  Under AII_HOME the lanes come from ~/.rao/aii/lanes.json, through a live
//        registry (AIILaneRegistry): an app registered after this Thread started is
//        found on a miss, and an admitted app with no lane gets one registered rather
//        than a lane nobody can resolve. A caller the keyring doesn't know is refused;
//        a session request without a known lane is refused rather than filed
//        somewhere. A Thread running open has no lanes: everything is
//        `LaneID.unscoped`.
//

import AII
import Foundation
import GRPCCore
import Seam

/// What a caller may read and write.
enum LaneScope: Equatable, Sendable {
    /// One lane — the caller's app's — or `.unscoped` where lanes don't apply.
    case lane(LaneID)
    /// Every lane: the stack identity. Reads see everything; writes are refused.
    case all

    /// The lane a write files under, or nil when this scope may not write.
    var writeLane: LaneID? {
        if case .lane(let id) = self { return id }
        return nil
    }

    /// Whether `lane` is within this scope.
    func admits(_ lane: LaneID?) -> Bool {
        switch self {
        case .all: return true
        case .lane(let own): return own.isUnscoped || lane == own
        }
    }

    /// The lane to filter by, or nil when nothing is filtered (`.all`, or unscoped).
    var filter: LaneID? {
        guard case .lane(let id) = self, !id.isUnscoped else { return nil }
        return id
    }
}

/// How a request arrived.
enum LaneCaller: Sendable {
    /// A direct RPC: the secret rides in the metadata (`x-ambient-secret`).
    case metadata(Metadata)
    /// A session request: Sewn stamped the lane of the app whose secret matched it.
    case trusted(lane: String)
    /// A test or an in-process caller that already knows its scope.
    case scope(LaneScope)
}

struct LaneResolver: Sendable {
    let stack: StackMode
    /// The registrations, live, when this Thread runs on a shared stack.
    let lanes: AIILaneRegistry?

    init(stack: StackMode, lanes: AIILaneRegistry?) {
        self.stack = stack
        self.lanes = lanes
    }

    /// A Thread that knows no lanes: open, or one app's.
    static let unscoped = LaneResolver(stack: .open, lanes: nil)

    var isMultiApp: Bool { stack.keyring != nil }

    /// The lane `app` files under on this stack, registered now when lanes.json has
    /// none for it. `failedPrecondition` when none can be: refused, never misfiled.
    func lane(for app: AIIApp) throws -> LaneID {
        guard isMultiApp else { return .unscoped }
        guard let lanes else {
            throw RPCError(code: .failedPrecondition, message: "this Thread has no lanes; \(app.rawValue)'s request is refused rather than misfiled")
        }
        do {
            return try lanes.id(for: app)
        } catch {
            throw RPCError(code: .failedPrecondition, message: "no lane could be registered for \(app.rawValue): \(error)")
        }
    }

    /// The scope of an admitted identity (HTTP).
    func scope(identity: StackIdentity?) throws -> LaneScope {
        guard isMultiApp else { return .lane(.unscoped) }
        switch identity {
        case .some(.stack): return .all
        case .some(.app(let app)): return .lane(try lane(for: app))
        case .none: return .lane(.unscoped)   // the middleware admits nothing unknown; a bare /health never gets here
        }
    }

    /// The scope of a caller, or an RPCError: `unauthenticated` for a secret the
    /// keyring doesn't know, `failedPrecondition` for a session request whose lane
    /// is missing or unregistered.
    func scope(for caller: LaneCaller) throws -> LaneScope {
        switch caller {
        case .scope(let scope):
            return scope
        case .metadata(let metadata):
            guard let keyring = stack.keyring else { return .lane(.unscoped) }
            let presented = StackSecretMetadata.presented(in: metadata)
            guard let identity = keyring.identity(forPresented: presented) else {
                throw RPCError(code: .unauthenticated, message: "no stack identity matches the secret presented")
            }
            return try scope(identity: identity)
        case .trusted(let stamped):
            guard isMultiApp else { return .lane(.unscoped) }
            guard !stamped.isEmpty else {
                throw RPCError(code: .failedPrecondition, message: "a session request on a shared stack must name its lane")
            }
            let lane = LaneID(rawValue: stamped)
            guard lanes?.contains(lane) == true else {
                throw RPCError(code: .failedPrecondition, message: "lane \(stamped) is not registered on this stack")
            }
            return .lane(lane)
        }
    }

    /// The lane a write under `scope` files into, or an RPCError when the scope may not write.
    func writeLane(_ scope: LaneScope) throws -> LaneID {
        guard let lane = scope.writeLane else {
            throw RPCError(code: .failedPrecondition, message: Self.stackCannotWrite)
        }
        return lane
    }

    static let stackCannotWrite = "the stack identity has no lane of its own: file as an app"

    /// Which app a lane belongs to, for messages.
    func appName(for lane: LaneID) -> String {
        if let lanes, let app = lanes.app(for: lane) { return lanes.displayName(for: app) }
        return lane.isUnscoped ? "no lane" : lane.rawValue
    }
}
