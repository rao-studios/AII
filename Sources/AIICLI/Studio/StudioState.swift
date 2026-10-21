//
//  StudioState.swift
//  AIICLI
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Everything the studio shows, as one value: the screen, what each screen read last,
//        what is running, what the last action said, and the prompt or overlay on top.
//  OUT:  StudioState, StudioJob (what a key asks the backend to do), StudioEvent (what the
//        backend answers).
//  PIN:  A value the update function changes and the render function reads; the processes,
//        files and network stay in the backend. One action at a time: `busy` names it.
//

import AII
import Foundation

enum Screen: Int, CaseIterable, Sendable {
    case index = 1, lanes, models, logs, doctor

    var title: String {
        switch self {
        case .index: return "Index"
        case .lanes: return "Lanes"
        case .models: return "Models"
        case .logs: return "Logs"
        case .doctor: return "Doctor"
        }
    }
}

/// One app's lane, as the Lanes screen lists it.
struct LaneRow: Equatable, Sendable {
    var name: String
    var displayName: String
    var lane: String?
    /// Whom its records are filed under with no account: aii-local or local-<name>.
    var owner: String?
    var secret: Bool
    var registeredBy: String?
    var registeredAt: Date?
    var bundleIdentifier: String?
    var documents: Int?
}

/// One lane walked down the stack: `d` on Lanes. Checks are nil while it runs.
struct LaneDoctorPane: Equatable {
    var name: String
    var checks: [DoctorCheck]?
}

/// What a key asks for; the backend does it with the same library call as the CLI verb.
enum StudioJob: Sendable, Equatable {
    // Reading.
    case refresh, lanes, models, doctor
    case logs(LaunchSpec.Role)
    case laneDoctor(String)
    // Acting.
    case install, update, start, stop, restart
    case addLane(name: String, displayName: String?)
    case setLaneOwner(name: String, owner: String)
    case removeLane(String)
    case pull(AIIModels.Role)
    case removeModel(AIIModels.Role)

    var isAction: Bool {
        switch self {
        case .refresh, .lanes, .models, .doctor, .logs, .laneDoctor: return false
        default: return true
        }
    }
}

/// What the backend answers.
enum StudioEvent: Sendable {
    case report(StatusReport)
    case lanes([LaneRow])
    case models([StatusReport.Model]?, problem: String?)
    case checks([DoctorCheck])
    case laneDoctor(String, [DoctorCheck])
    case log(LaunchSpec.Role, [String])
    /// An action started.
    case busy(String)
    /// A line from the running action.
    case progress(String)
    /// The action finished, and what it did.
    case done(String)
    case failed(String, hint: String?)
}

/// A question the studio is waiting on an answer to.
enum Prompt: Equatable {
    /// `a` on Lanes: the name, then the display name.
    case laneName(TextFieldState, problem: String?)
    case laneDisplay(name: String, TextFieldState)
    /// `o` on Lanes: y files the lane under `to` from now on.
    case laneOwner(name: String, to: String)
    /// `x` on Lanes: the name typed again.
    case removeLane(name: String, TextFieldState, problem: String?)
    /// `x` on Models: y to remove.
    case removeModel(AIIModels.Role)
}

struct StudioState {
    var screen: Screen = .index

    var report: StatusReport?
    var lanes: [LaneRow] = []
    var lanesRead = false
    var lanesTable = TableState(selected: 0)
    var models: [StatusReport.Model]?
    var modelsProblem: String?
    var modelsTable = TableState(selected: 0)
    var logRole: LaunchSpec.Role = .sewn
    var logLines: [LaunchSpec.Role: [String]] = [:]
    var checks: [DoctorCheck] = []
    var doctorRan = false

    /// The action running now.
    var busy: String?
    var progress: String?
    var message: String?
    var problem: (message: String, hint: String?)?

    var prompt: Prompt?
    var details: LaneRow?
    var laneDoctor: LaneDoctorPane?
    var showHelp = false

    var ticks = 0
    var quitCode: Int32?
    var redraw = false

    var selectedLane: LaneRow? {
        guard let index = lanesTable.selected, lanes.indices.contains(index) else { return nil }
        return lanes[index]
    }

    var selectedModel: AIIModels.Entry? {
        guard let index = modelsTable.selected, AIIModels.all.indices.contains(index) else { return nil }
        return AIIModels.all[index]
    }

    var stackIsUp: Bool { report?.servers.allSatisfy(\.healthy) ?? false }
    var installIsYours: Bool { report?.install?.source == AIIInstallSource.local.rawValue }
}
