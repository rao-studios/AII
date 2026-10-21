//
//  StudioApp.swift
//  AIICLI
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The studio's three pure functions: handle an event (and say what the backend should
//        do), apply what the backend answered, render a frame. The chrome — title, tabs,
//        status line, key hints, help and prompts — lives here; each screen draws its panel.
//  PIN:  The shape of Braid's studio (Sources/BraidStudio/StudioApp.swift). One shortest
//        path per outcome: a key does one thing, the same thing as its CLI verb. Nothing here
//        touches a file or a process; tests drive it with events and read the canvas.
//

import AII
import Foundation

enum StudioApp {

    /// What the studio reads when it opens.
    static let initialJobs: [StudioJob] = [.refresh, .lanes]

    // MARK: - Events

    static func handle(_ event: Event<StudioEvent>, state: inout StudioState) -> [StudioJob] {
        switch event {
        case .key(let key):
            return self.key(key, &state)
        case .tick:
            state.ticks += 1
            return periodic(&state)
        case .resize:
            state.redraw = true
            return []
        case .signal(let signal):
            if signal != .interrupt { state.quitCode = 0 }
            return []
        case .message(let message):
            return apply(message, &state)
        case .inputClosed:
            state.quitCode = 0
            return []
        }
    }

    /// The stack is read again every 3 s; the visible log every second; a download's
    /// progress every 2 s.
    static func periodic(_ state: inout StudioState) -> [StudioJob] {
        var jobs: [StudioJob] = []
        if state.ticks % 30 == 0 {
            jobs.append(.refresh)
            if state.screen == .lanes { jobs.append(.lanes) }
        }
        if state.screen == .logs, state.ticks % 10 == 0 { jobs.append(.logs(state.logRole)) }
        if state.screen == .models, state.ticks % 20 == 0 { jobs.append(.models) }
        return jobs
    }

    static func apply(_ event: StudioEvent, _ state: inout StudioState) -> [StudioJob] {
        switch event {
        case .report(let report):
            state.report = report
        case .lanes(let rows):
            state.lanes = rows
            state.lanesRead = true
            let visible = max(1, rows.count)
            state.lanesTable.clamp(rowCount: rows.count, visible: visible)
        case .models(let models, let problem):
            state.models = models
            state.modelsProblem = problem
        case .checks(let checks):
            state.checks = checks
            state.doctorRan = true
        case .laneDoctor(let name, let checks):
            // A pane closed before its checks came back stays closed.
            if state.laneDoctor?.name == name { state.laneDoctor?.checks = checks }
        case .log(let role, let lines):
            state.logLines[role] = lines
        case .busy(let label):
            state.busy = label
            state.progress = nil
            state.message = nil
            state.problem = nil
        case .progress(let line):
            state.progress = line
        case .done(let message):
            state.busy = nil
            state.progress = nil
            state.message = message
            return [.refresh, .lanes] + (state.screen == .models ? [.models] : [])
        case .failed(let message, let hint):
            state.busy = nil
            state.progress = nil
            state.problem = (message, hint)
            return [.refresh]
        }
        return []
    }

    // MARK: - Keys

    static func key(_ event: KeyEvent, _ state: inout StudioState) -> [StudioJob] {
        if state.showHelp {
            state.showHelp = false
            return []
        }
        if state.details != nil {
            state.details = nil
            return []
        }
        if state.laneDoctor != nil {
            state.laneDoctor = nil
            return []
        }
        if state.prompt != nil { return promptKey(event, &state) }
        switch event.key {
        case .char("q"):
            state.quitCode = 0
            return []
        case .char("?"):
            state.showHelp = true
            return []
        case .char(let c) where c.isNumber:
            guard let number = c.wholeNumberValue, let screen = Screen(rawValue: number) else { return [] }
            return show(screen, &state)
        default:
            break
        }
        let jobs: [StudioJob]
        switch state.screen {
        case .index: jobs = IndexScreen.key(event, &state)
        case .lanes: jobs = LanesScreen.key(event, &state)
        case .models: jobs = ModelsScreen.key(event, &state)
        case .logs: jobs = LogsScreen.key(event, &state)
        case .doctor: jobs = DoctorScreen.key(event, &state)
        }
        return admit(jobs, &state)
    }

    /// One action at a time: a second one waits until the first has finished.
    static func admit(_ jobs: [StudioJob], _ state: inout StudioState) -> [StudioJob] {
        guard let busy = state.busy, jobs.contains(where: \.isAction) else { return jobs }
        state.message = "one thing at a time: \(busy) is still running"
        return jobs.filter { !$0.isAction }
    }

    static func show(_ screen: Screen, _ state: inout StudioState) -> [StudioJob] {
        state.screen = screen
        switch screen {
        case .index: return [.refresh]
        case .lanes: return [.lanes]
        case .models: return [.models]
        case .logs: return [.logs(state.logRole)]
        case .doctor: return state.doctorRan ? [] : [.doctor]
        }
    }

    static func promptKey(_ event: KeyEvent, _ state: inout StudioState) -> [StudioJob] {
        guard let prompt = state.prompt else { return [] }
        if event.key == .escape {
            state.prompt = nil
            return []
        }
        switch prompt {
        case .laneName(var field, _):
            if event.key == .enter {
                do {
                    let app = try AIIApp.named(field.text.trimmingCharacters(in: .whitespaces))
                    state.prompt = .laneDisplay(name: app.rawValue, TextFieldState(app.displayName))
                } catch {
                    state.prompt = .laneName(field, problem: AIIFailure.sentence("\(error)"))
                }
                return []
            }
            _ = field.handle(event)
            state.prompt = .laneName(field, problem: nil)
        case .laneDisplay(let name, var field):
            if event.key == .enter {
                state.prompt = nil
                let display = field.text.trimmingCharacters(in: .whitespaces)
                return admit([.addLane(name: name, displayName: display.isEmpty ? nil : display)], &state)
            }
            _ = field.handle(event)
            state.prompt = .laneDisplay(name: name, field)
        case .laneOwner(let name, let owner):
            state.prompt = nil
            if event.key == .char("y") { return admit([.setLaneOwner(name: name, owner: owner)], &state) }
        case .removeLane(let name, var field, _):
            if event.key == .enter {
                guard field.text == name else {
                    state.prompt = .removeLane(name: name, field, problem: "type \(name) to remove it")
                    return []
                }
                state.prompt = nil
                return admit([.removeLane(name)], &state)
            }
            _ = field.handle(event)
            state.prompt = .removeLane(name: name, field, problem: nil)
        case .removeModel(let role):
            state.prompt = nil
            if event.key == .char("y") { return admit([.removeModel(role)], &state) }
        }
        return []
    }

    // MARK: - Rendering

    static func render(_ state: StudioState, _ frame: inout Frame) {
        let bounds = frame.bounds
        let (header, rest) = bounds.top(2)
        let (footer, body) = rest.bottom(2)
        renderHeader(state, &frame, header)
        let panel = Box.panel("\(state.screen.rawValue) \(state.screen.title)", focused: true, palette: frame.palette, glyphs: frame.glyphs)
            .render(in: body, on: &frame.canvas)
        switch state.screen {
        case .index: IndexScreen.render(state, &frame, panel)
        case .lanes: LanesScreen.render(state, &frame, panel)
        case .models: ModelsScreen.render(state, &frame, panel)
        case .logs: LogsScreen.render(state, &frame, panel)
        case .doctor: DoctorScreen.render(state, &frame, panel)
        }
        renderStatus(state, &frame, footer.row(0))
        renderHints(state, &frame, footer.row(1))
        if state.showHelp {
            renderHelp(&frame)
        } else if let prompt = state.prompt {
            renderPrompt(prompt, &frame)
        } else if let details = state.details {
            LanesScreen.renderDetails(details, &frame)
        } else if let pane = state.laneDoctor {
            LanesScreen.renderDoctor(pane, &frame)
        }
    }

    static func renderHeader(_ state: StudioState, _ frame: inout Frame, _ rect: Rect) {
        let palette = frame.palette
        var title = Text(" AII", style: palette.gold.bold())
        title.append("  Ambient Intelligence Index", palette.text)
        if let report = state.report { title.append("  ·  " + tilde(report.home), palette.dim) }
        frame.canvas.put(title.truncated(to: rect.width), x: rect.minX, y: rect.minY, clip: rect)
        if let busy = state.busy {
            let spinner = frame.glyphs.spinner[state.ticks % frame.glyphs.spinner.count]
            let right = Text(spinner + " " + busy + " ", style: palette.orange)
            frame.canvas.put(right, x: rect.maxX - right.width, y: rect.minY, clip: rect)
        }
        let titles: [Text] = Screen.allCases.map { screen in
            let chosen = screen == state.screen
            var text = Text("\(screen.rawValue) ", style: chosen ? palette.gold : palette.muted)
            text.append(screen.title, chosen ? palette.blue.bold() : palette.dim)
            return text
        }
        Tabs(titles, selected: state.screen.rawValue - 1, style: palette.dim, selectedStyle: palette.blue.bold(),
             separator: Text("   ", style: palette.dim)).render(in: rect.row(1).inset(left: 1), on: &frame.canvas)
    }

    static func renderStatus(_ state: StudioState, _ frame: inout Frame, _ rect: Rect) {
        let palette = frame.palette
        var text = Text(" ")
        if let problem = state.problem {
            text.append("aii: " + problem.message, palette.error)
            if let hint = problem.hint { text.append(" → " + hint, palette.dim) }
        } else if let progress = state.progress {
            text.append(progress, palette.dim)
        } else if let message = state.message {
            text.append(message, palette.text)
        }
        frame.canvas.put(text.truncated(to: rect.width), x: rect.minX, y: rect.minY, clip: rect)
    }

    static func renderHints(_ state: StudioState, _ frame: inout Frame, _ rect: Rect) {
        let palette = frame.palette
        let screen: [KeyHint]
        switch state.screen {
        case .index: screen = IndexScreen.hints(state)
        case .lanes: screen = LanesScreen.hints(state)
        case .models: screen = ModelsScreen.hints(state)
        case .logs: screen = LogsScreen.hints
        case .doctor: screen = DoctorScreen.hints
        }
        let hints = screen + [KeyHint("1–5", "screens"), KeyHint("?", "keys"), KeyHint("q", "quit")]
        KeyHintBar(hints, keyStyle: palette.hintKey, labelStyle: palette.hintLabel)
            .render(in: rect.inset(left: 1), on: &frame.canvas)
    }

    static let helpLines: [(String, String)] = [
        ("1–5", "Index, Lanes, Models, Logs, Doctor"),
        ("i", "Index: build this checkout and install it as your build"),
        ("u", "Index: rebuild your build from its checkout"),
        ("s", "Index: start the stack, or stop it when no app holds it"),
        ("r", "Index: restart both servers onto the installed build"),
        ("a", "Lanes: add a lane: a name, then a display name"),
        ("o", "Lanes: switch the selected lane's owner between aii-local and local-<name>"),
        ("d", "Lanes: walk the selected lane down the stack and name the layer to fix"),
        ("x", "Lanes: remove the selected lane (type its name); Models: remove the selected model"),
        ("⏎", "Lanes: the selected lane's details"),
        ("p", "Models: pull the selected model"),
        ("tab", "Logs: Sewn's or Thread's"),
        ("r", "Doctor: run the checks again"),
        ("esc", "close a prompt"),
        ("q", "quit; two Ctrl-Cs always do"),
    ]

    static func renderHelp(_ frame: inout Frame) {
        let palette = frame.palette
        frame.canvas.restyle(frame.bounds) { $0.adding(.dim) }
        let width = min(frame.size.width - 4, 92)
        let rect = frame.bounds.centered(width: width, height: min(frame.size.height - 2, helpLines.count + 2))
        frame.canvas.fill(rect, style: palette.base)
        let inner = Box(title: Text("Keys", style: palette.title), footer: Text("any key closes", style: palette.dim),
                        style: palette.focusBorder, glyphs: frame.glyphs).render(in: rect, on: &frame.canvas)
        for (row, (key, label)) in helpLines.prefix(inner.height).enumerated() {
            let line = Text(key.padding(toLength: 6, withPad: " ", startingAt: 0), style: palette.hintKey) + Text(label, style: palette.text)
            frame.canvas.put(line.truncated(to: inner.width - 1), x: inner.minX + 1, y: inner.minY + row, clip: inner)
        }
    }

    static func renderPrompt(_ prompt: Prompt, _ frame: inout Frame) {
        let palette = frame.palette
        let title: String
        let question: String
        var field: TextFieldState?
        var problem: String?
        var note: String?
        switch prompt {
        case .laneName(let state, let why):
            (title, question, field, problem) = ("Add a lane", "Its name: 2 to 32 of a-z and 0-9, starting with a letter", state, why)
        case .laneDisplay(let name, let state):
            (title, question, field) = ("Add \(name)", "How people read it", state)
        case .laneOwner(let name, let owner):
            (title, question) = ("Owner of \(name)", "Switch \(name)'s owner to \(owner)? y switches, any other key keeps it")
            note = "Documents already filed keep their owner until they're filed again"
        case .removeLane(let name, let state, let why):
            (title, question, field, problem) = ("Remove \(name)", "Type \(name) to remove its secret and manifest entry; its documents stay", state, why)
        case .removeModel(let role):
            (title, question) = ("Remove \(role.rawValue)", "Delete it from this Mac? y removes, any other key keeps it")
        }
        frame.canvas.restyle(frame.bounds) { $0.adding(.dim) }
        let width = min(frame.size.width - 4, 80)
        let rect = frame.bounds.centered(width: width, height: field == nil ? 4 : 6)
        frame.canvas.fill(rect, style: palette.base)
        let footer = field == nil ? "y confirms · any other key cancels" : "⏎ confirms · esc cancels"
        let inner = Box(title: Text(title, style: palette.title), footer: Text(footer, style: palette.dim),
                        style: palette.focusBorder, glyphs: frame.glyphs).render(in: rect, on: &frame.canvas)
        frame.canvas.put(Text(question, style: palette.text).truncated(to: inner.width - 2), x: inner.minX + 1, y: inner.minY, clip: inner)
        if let note {
            frame.canvas.put(Text(note, style: palette.dim).truncated(to: inner.width - 2), x: inner.minX + 1, y: inner.minY + 1, clip: inner)
        }
        if let field {
            let line = inner.row(2).inset(left: 1, right: 1)
            frame.cursor = TextField(state: field, focused: true, style: palette.text, placeholderStyle: palette.dim,
                                     cursorStyle: palette.cursor).render(in: line, on: &frame.canvas)
            if let problem {
                frame.canvas.put(Text(problem, style: palette.error).truncated(to: inner.width - 2), x: inner.minX + 1, y: inner.minY + 3, clip: inner)
            }
        }
    }

    /// A status row as the studio draws it: the label dim, ✓ green, ✗ red, the fix after → gold.
    static func styledRow(_ line: String, palette: Palette) -> Text {
        let label = String(line.prefix(10))
        var value = String(line.dropFirst(10))
        var text = Text(label, style: palette.dim)
        var fix: String?
        if let arrow = value.range(of: " → ") {
            fix = String(value[arrow.upperBound...])
            value = String(value[..<arrow.lowerBound])
        }
        if value.hasPrefix("✓") {
            text.append("✓", palette.green)
            value.removeFirst()
        } else if value.hasPrefix("✗") {
            text.append("✗", palette.red)
            value.removeFirst()
        }
        text.append(value, palette.text)
        if let fix { text.append(" → " + fix, palette.gold) }
        return text
    }
}
