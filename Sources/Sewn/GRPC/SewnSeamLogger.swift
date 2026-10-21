//
//  SewnSeamLogger.swift
//  Sewn
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//

import Seam

/// Routes Conduit's gRPC session/client logs through SewnLogger so the
/// structured Cockpit JSON lines (service label "Sewn") keep flowing.
struct SewnSeamLogger: SeamLogger {
    let base: SewnLogger

    func debug(_ label: String?, _ message: String)   { base.debug(label, "\(message)", service: .sewn) }
    func info(_ label: String?, _ message: String)    { base.info(label, "\(message)", service: .sewn) }
    func warning(_ label: String?, _ message: String) { base.warning(label: label, "\(message)", service: .sewn) }
    func error(_ label: String?, _ message: String)   { base.error(label, "\(message)", service: .sewn) }
}
