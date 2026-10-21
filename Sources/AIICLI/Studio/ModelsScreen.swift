//
//  ModelsScreen.swift
//  AIICLI
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Screen 3: every pinned model, whether it is on this Mac, and a download's progress;
//        pulling or removing the selected one.
//  PIN:  Through Sewn, as `aii models` is: with Sewn down the screen says so.
//

import AII
import Foundation

enum ModelsScreen {

    static func key(_ event: KeyEvent, _ state: inout StudioState) -> [StudioJob] {
        let count = AIIModels.all.count
        switch event.key {
        case .up, .char("k"): state.modelsTable.move(by: -1, rowCount: count, visible: count)
        case .down, .char("j"): state.modelsTable.move(by: 1, rowCount: count, visible: count)
        case .char("p"):
            if let entry = state.selectedModel { return [.pull(entry.role)] }
        case .char("x"):
            if let entry = state.selectedModel { state.prompt = .removeModel(entry.role) }
        default: break
        }
        return []
    }

    static func hints(_ state: StudioState) -> [KeyHint] { [KeyHint("p", "pull"), KeyHint("x", "remove")] }

    static func render(_ state: StudioState, _ frame: inout Frame, _ rect: Rect) {
        let palette = frame.palette
        let rows: [[Text]] = AIIModels.all.map { entry in
            let model = state.models?.first { $0.id == entry.id }
            let disk: Text
            switch model?.state {
            case "installed": disk = Text(frame.glyphs.check + " on this Mac" + (model?.kept == true ? " · kept" : ""), style: palette.green)
            case "downloading": disk = Text("… " + (model?.progress.map { "\(Int($0 * 100))%" } ?? "downloading"), style: palette.orange)
            case "absent": disk = Text(frame.glyphs.cross + " absent", style: palette.dim)
            case let other?: disk = Text(other, style: palette.red)
            case nil: disk = Text("–", style: palette.dim)
            }
            return [Text(entry.role.rawValue, style: palette.text), Text(entry.id, style: palette.dim),
                    Text(entry.revision.map { String($0.prefix(8)) } ?? "unpinned", style: palette.muted), disk]
        }
        let (bottom, top) = rect.bottom(1)
        Table.styled(columns: [Column("Role", .fixed(17)), Column("Model", .flex(1)), Column("Revision", .fixed(10)),
                               Column("On this Mac", .fixed(22))],
                     rows: rows, state: state.modelsTable, palette: palette, glyphs: frame.glyphs)
            .render(in: top.inset(left: 1, right: 1), on: &frame.canvas)
        if state.models == nil {
            let why = state.modelsProblem ?? "reading the models…"
            frame.canvas.put(Text(why, style: palette.warn).truncated(to: rect.width - 2), x: rect.minX + 1, y: bottom.minY, clip: rect)
        }
    }
}
