//
//  LanesScreen.swift
//  AIICLI
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Screen 2: every lane in the manifest — display name, owner, lane id, secret,
//        documents — and adding one, switching its owner, walking it down the stack with the
//        lane doctor, or removing it.
//  PIN:  Adding asks the name, then the display name; switching the owner asks y; removing
//        asks for the name typed again. Each calls what `aii lanes add`, `owner`, `doctor` and
//        `remove` call. The owner switches between aii-local and local-<name>.
//

import AII
import Foundation

enum LanesScreen {

    static func key(_ event: KeyEvent, _ state: inout StudioState) -> [StudioJob] {
        let visible = max(1, state.lanes.count)
        switch event.key {
        case .up, .char("k"): state.lanesTable.move(by: -1, rowCount: state.lanes.count, visible: visible)
        case .down, .char("j"): state.lanesTable.move(by: 1, rowCount: state.lanes.count, visible: visible)
        case .char("a"): state.prompt = .laneName(TextFieldState(), problem: nil)
        case .char("o"):
            if let lane = state.selectedLane, let owner = lane.owner {
                let shared = AIIOwner.local.rawValue
                state.prompt = .laneOwner(name: lane.name, to: owner == shared ? "local-\(lane.name)" : shared)
            }
        case .char("d"):
            if let lane = state.selectedLane {
                state.laneDoctor = LaneDoctorPane(name: lane.name, checks: nil)
                return [.laneDoctor(lane.name)]
            }
        case .char("x"):
            if let lane = state.selectedLane { state.prompt = .removeLane(name: lane.name, TextFieldState(), problem: nil) }
        case .enter: state.details = state.selectedLane
        default: break
        }
        return []
    }

    static func hints(_ state: StudioState) -> [KeyHint] {
        [KeyHint("a", "add"), KeyHint("o", "owner"), KeyHint("d", "doctor"), KeyHint("x", "remove"), KeyHint("⏎", "details")]
    }

    static func render(_ state: StudioState, _ frame: inout Frame, _ rect: Rect) {
        let palette = frame.palette
        let (bottom, top) = rect.bottom(2)
        guard state.lanesRead else {
            frame.canvas.put(Text("reading the lanes…", style: palette.dim), x: rect.minX + 1, y: rect.minY, clip: rect)
            return
        }
        if state.lanes.isEmpty {
            frame.canvas.put(Text("No lanes yet. Press a to add one, or launch a Rao app.", style: palette.text),
                             x: rect.minX + 1, y: rect.minY, clip: rect)
        } else {
            let strands = [AIIApp.ambient.rawValue: palette.blue, AIIApp.craft.rawValue: palette.green, AIIApp.veil.rawValue: palette.orange]
            let rows: [[Text]] = state.lanes.map { lane in
                [Text(lane.name, style: strands[lane.name] ?? palette.text),
                 Text(lane.displayName, style: palette.text),
                 Text(lane.owner ?? "–", style: lane.owner == AIIOwner.local.rawValue ? palette.gold : palette.text),
                 Text(lane.lane ?? "no lane → aii lanes add \(lane.name)", style: lane.lane == nil ? palette.warn : palette.dim),
                 Text(lane.secret ? frame.glyphs.check : frame.glyphs.cross, style: lane.secret ? palette.green : palette.red),
                 Text(lane.documents.map(String.init) ?? "–", style: palette.text)]
            }
            Table.styled(columns: [Column("Name", .fixed(12)), Column("Display", .fixed(16)), Column("Owner", .fixed(14)),
                                   Column("Lane", .fixed(38)), Column("Secret", .fixed(7)),
                                   Column("Documents", .flex(1), align: .trailing)],
                         rows: rows, state: state.lanesTable, palette: palette, glyphs: frame.glyphs)
                .render(in: top.inset(left: 1, right: 1), on: &frame.canvas)
        }
        let tip = Text("A custom lane fills when its app runs: ", style: palette.dim)
            + Text("swift run --package-path Examples/Notes", style: palette.muted)
        frame.canvas.put(tip.truncated(to: rect.width - 2), x: rect.minX + 1, y: bottom.minY + 1, clip: rect)
    }

    static func renderDetails(_ lane: LaneRow, _ frame: inout Frame) {
        let palette = frame.palette
        frame.canvas.restyle(frame.bounds) { $0.adding(.dim) }
        let rows: [(String, String)] = [
            ("name", lane.name),
            ("display", lane.displayName),
            ("owner", lane.owner.map { "\($0), with no account · o switches it" } ?? "—"),
            ("lane", lane.lane ?? "none yet: aii lanes add \(lane.name)"),
            ("secret", lane.secret ? "secrets/\(lane.name), 0600" : "none"),
            ("documents", lane.documents.map(String.init) ?? "Thread didn't say"),
            ("registered", [lane.registeredBy.map { "by \($0)" }, lane.registeredAt.map(Stamp.minute)]
                .compactMap { $0 }.joined(separator: " · ")),
            ("bundle", lane.bundleIdentifier ?? "—"),
            ("manifest", "aii/lanes.json"),
        ]
        let rect = frame.bounds.centered(width: min(frame.size.width - 4, 76), height: rows.count + 2)
        frame.canvas.fill(rect, style: palette.base)
        let inner = Box(title: Text(lane.displayName, style: palette.title), footer: Text("any key closes", style: palette.dim),
                        style: palette.focusBorder, glyphs: frame.glyphs).render(in: rect, on: &frame.canvas)
        for (row, (label, value)) in rows.enumerated() where row < inner.height {
            let line = Text(label.padding(toLength: 11, withPad: " ", startingAt: 0), style: palette.dim) + Text(value, style: palette.text)
            frame.canvas.put(line.truncated(to: inner.width - 1), x: inner.minX + 1, y: inner.minY + row, clip: inner)
        }
    }

    /// The lane doctor's pane: each layer, top down, with its fix.
    static func renderDoctor(_ pane: LaneDoctorPane, _ frame: inout Frame) {
        let palette = frame.palette
        frame.canvas.restyle(frame.bounds) { $0.adding(.dim) }
        let checks = pane.checks ?? []
        let rect = frame.bounds.centered(width: min(frame.size.width - 4, 100),
                                         height: min(frame.size.height - 2, max(checks.count, 1) + 4))
        frame.canvas.fill(rect, style: palette.base)
        let inner = Box(title: Text("\(pane.name) · lane doctor", style: palette.title),
                        footer: Text("any key closes", style: palette.dim),
                        style: palette.focusBorder, glyphs: frame.glyphs).render(in: rect, on: &frame.canvas)
        guard let found = pane.checks else {
            frame.canvas.put(Text("walking \(pane.name) down the stack…", style: palette.dim), x: inner.minX + 1, y: inner.minY, clip: inner)
            return
        }
        for (row, check) in found.enumerated() where row < inner.height - 2 {
            var line = Text(check.ok ? frame.glyphs.check : frame.glyphs.cross, style: check.ok ? palette.green : palette.red)
            line.append(" " + check.name.padding(toLength: 10, withPad: " ", startingAt: 0), palette.text)
            line.append(check.detail, palette.dim)
            if let fix = check.fix { line.append(" → " + fix, palette.gold) }
            frame.canvas.put(line.truncated(to: inner.width - 1), x: inner.minX + 1, y: inner.minY + row, clip: inner)
        }
        let failing = found.first { !$0.ok }
        let summary = failing.map { Text("fix \($0.name) first: the layers above it wait on it", style: palette.red) }
            ?? Text("every layer passed", style: palette.green)
        frame.canvas.put(summary.truncated(to: inner.width - 1), x: inner.minX + 1,
                         y: min(inner.maxY - 1, inner.minY + found.count + 1), clip: inner)
    }
}
