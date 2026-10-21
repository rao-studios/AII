//
//  LogsScreen.swift
//  AIICLI
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Screen 4: Sewn's or Thread's log, its last lines, followed while the screen is up.
//

import AII
import Foundation

enum LogsScreen {

    static func key(_ event: KeyEvent, _ state: inout StudioState) -> [StudioJob] {
        guard event.key == .tab || event.key == .backTab else { return [] }
        state.logRole = state.logRole == .sewn ? .thread : .sewn
        return [.logs(state.logRole)]
    }

    static let hints = [KeyHint("tab", "Sewn ⇄ Thread")]

    static func render(_ state: StudioState, _ frame: inout Frame, _ rect: Rect) {
        let palette = frame.palette
        let name = state.logRole == .sewn ? "sewn.log" : "thread.log"
        let title = Text(state.logRole.displayName, style: palette.blue.bold()) + Text(" · aii/run/\(name)", style: palette.dim)
        frame.canvas.put(title, x: rect.minX + 1, y: rect.minY, clip: rect)
        let body = rect.inset(top: 1, left: 1, right: 1)
        let lines = state.logLines[state.logRole] ?? []
        guard !lines.isEmpty else {
            frame.canvas.put(Text("no log yet: start the stack (1, then s)", style: palette.dim), x: body.minX, y: body.minY, clip: body)
            return
        }
        for (row, line) in lines.suffix(body.height).enumerated() {
            frame.canvas.put(Text(line, style: palette.text).truncated(to: body.width), x: body.minX, y: body.minY + row, clip: body)
        }
    }
}
