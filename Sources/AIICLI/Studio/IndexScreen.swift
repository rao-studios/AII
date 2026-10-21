//
//  IndexScreen.swift
//  AIICLI
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Screen 1: what `aii status` says — whose build, the contract, both servers, who
//        holds them, the lanes, the models — live, and the keys that act on the stack.
//  PIN:  The rows are Render.status's, the same text the command prints. An empty home is a
//        state, not an error: it says nothing is installed and offers `i`.
//

import AII
import Foundation

enum IndexScreen {

    static func key(_ event: KeyEvent, _ state: inout StudioState) -> [StudioJob] {
        switch event.key {
        case .char("i"): return [.install]
        case .char("u"):
            guard state.installIsYours else {
                state.message = "u updates your build; press i to make one"
                return []
            }
            return [.update]
        case .char("s"): return [state.stackIsUp ? .stop : .start]
        case .char("r"): return [.restart]
        default: return []
        }
    }

    static func hints(_ state: StudioState) -> [KeyHint] {
        var hints = [KeyHint("i", "install your build")]
        if state.installIsYours { hints.append(KeyHint("u", "update")) }
        hints.append(KeyHint("s", state.stackIsUp ? "stop" : "start"))
        hints.append(KeyHint("r", "restart"))
        return hints
    }

    static func render(_ state: StudioState, _ frame: inout Frame, _ rect: Rect) {
        let palette = frame.palette
        guard let report = state.report else {
            frame.canvas.put(Text("reading the stack…", style: palette.dim), x: rect.minX + 1, y: rect.minY, clip: rect)
            return
        }
        var row = 0
        for line in Render.status(report) where row < rect.height {
            frame.canvas.put(StudioApp.styledRow(line, palette: palette).truncated(to: rect.width - 2),
                             x: rect.minX + 1, y: rect.minY + row, clip: rect)
            row += 1
        }
        if report.install == nil, !report.installUnreadable, row + 1 < rect.height {
            let call = Text("Nothing is installed. Press ", style: palette.text) + Text("i", style: palette.hintKey)
                + Text(" to build AII from this checkout and install it as your build.", style: palette.text)
            frame.canvas.put(call.truncated(to: rect.width - 2), x: rect.minX + 1, y: rect.minY + row + 1, clip: rect)
        }
    }
}
