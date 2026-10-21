//
//  DoctorScreen.swift
//  AIICLI
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Screen 5: `aii doctor`'s checks, each with its fix.
//

import AII
import Foundation

enum DoctorScreen {

    static func key(_ event: KeyEvent, _ state: inout StudioState) -> [StudioJob] {
        event.key == .char("r") ? [.doctor] : []
    }

    static let hints = [KeyHint("r", "run again")]

    static func render(_ state: StudioState, _ frame: inout Frame, _ rect: Rect) {
        let palette = frame.palette
        guard state.doctorRan else {
            frame.canvas.put(Text("running the checks…", style: palette.dim), x: rect.minX + 1, y: rect.minY, clip: rect)
            return
        }
        for (row, check) in state.checks.enumerated() where row < rect.height - 2 {
            var line = Text(check.ok ? frame.glyphs.check : frame.glyphs.cross, style: check.ok ? palette.green : palette.red)
            line.append(" " + check.name.padding(toLength: 11, withPad: " ", startingAt: 0), palette.text)
            line.append(check.detail, palette.dim)
            if let fix = check.fix { line.append(" → " + fix, palette.gold) }
            frame.canvas.put(line.truncated(to: rect.width - 2), x: rect.minX + 1, y: rect.minY + row, clip: rect)
        }
        let failed = state.checks.filter { !$0.ok }.count
        let summary = failed == 0 ? Text("all checks passed", style: palette.green)
            : Text("\(failed) check\(failed == 1 ? "" : "s") failed", style: palette.red)
        frame.canvas.put(summary, x: rect.minX + 1, y: min(rect.maxY - 1, rect.minY + state.checks.count + 1), clip: rect)
    }
}
