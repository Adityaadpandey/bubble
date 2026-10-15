import AppKit
import ServiceManagement
import Carbon
import Combine
import SwiftUI

let hookNote = Notification.Name("dev.notiapp.hook")
let patternsFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/notiapp/patterns.txt")

// Hook mode: Claude Code runs `NotiApp hook` with the event JSON on stdin.
// We boil it down to a few strings, hand them to the running app and exit right away,
// so Claude never waits on us and shows its own prompt as usual.
if CommandLine.arguments.dropFirst().first == "hook" {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    // ITERM_SESSION_ID looks like "w0t5p0:3B3A957A-...", the part after the colon is iTerm2's session id
    guard let session = ProcessInfo.processInfo.environment["ITERM_SESSION_ID"]?.split(separator: ":").last else { exit(0) }

    // "- old line" / "+ new line", capped so a huge Write doesn't flood the card
    func diffLines(_ text: Any?, _ sign: String) -> [String] {
        ((text as? String) ?? "").components(separatedBy: .newlines).prefix(6).map { "\(sign) \($0)" }
    }

    var info: [String: String]
    switch obj["hook_event_name"] as? String {
    case "PermissionRequest":
        let tool = obj["tool_name"] as? String ?? "Tool"
        let input = obj["tool_input"] as? [String: Any] ?? [:]
        let path = input["file_path"] as? String ?? ""
        var title = tool, body = "", diff: [String] = []
        switch tool {
        case "Bash":
            body = "$ " + (input["command"] as? String ?? "")
            if let what = input["description"] as? String { title = "Bash · \(what)" }
        case "Edit":
            title = "Edit · \((path as NSString).lastPathComponent)"
            body = path
            diff = diffLines(input["old_string"], "-") + diffLines(input["new_string"], "+")
        case "Write":
            title = "Write · \((path as NSString).lastPathComponent)"
            body = path
            diff = diffLines(input["content"], "+")
        default:
            body = ["command", "file_path", "url", "pattern", "query", "prompt"].lazy.compactMap { input[$0] as? String }.first ?? ""
        }
        info = ["kind": "detail", "title": title, "body": String(body.prefix(400)), "diff": diff.joined(separator: "\n")]
    case "Notification":
        let message = obj["message"] as? String ?? ""
        guard message.contains("waiting for your input") else { exit(0) } // permission ones are caught on screen
        info = ["kind": "idle", "body": message]
    default:
        exit(0)
    }
    DistributedNotificationCenter.default().postNotificationName(hookNote, object: String(session), userInfo: info, deliverImmediately: true)
    exit(0)
}

// ~/Library/Logs/NotiApp.log, one line per card opened or closed and per answer sent, e.g.
//   2026-10-15T19:07:12Z answer 3B3A… pick(1) keys ["\u{1B}[B", "\r"] trusted card: false
let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/NotiApp.log")
func log(_ message: String) {
    let line = "\(Date().formatted(.iso8601)) \(message)\n"
    guard let h = try? FileHandle(forWritingTo: logURL) else {
        try? line.write(to: logURL, atomically: true, encoding: .utf8)
        return
    }
    h.seekToEndOfFile()
    h.write(Data(line.utf8))
    try? h.close()
}

final class App: NSObject, NSApplicationDelegate {
    var cards: [String: CardModel] = [:]      // one live card per iTerm2 session that's waiting on you
    var panels: [String: CardPanel] = [:]
    var order: [String] = []                  // oldest card on top, newer ones stack below it
    var hidden: Set<String> = []              // you pressed ✕, stays hidden until that prompt is gone
    var details: [String: Detail] = [:]       // latest tool call per session, from the hook
    var changed: [String: (tail: String, at: Date)] = [:] // when each tab's screen last changed
    var inFlight: [String: Int] = [:]         // answers whose keys haven't all landed yet
    var typedAt: [String: Date] = [:]         // when our last keys finished landing in each tab
    var known: [String: Session] = [:]        // every tab as of the last read
    var front = ""                            // the tab in front in iTerm2
    var reading = false
    let iterm = ITerm()
    var patterns: [NSRegularExpression] = []
    var hotKey: HotKey?
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let dashboard = Dashboard()
    var dashPanel: NotchPanel?
    var dashClosedAt = Date.distantPast
    var notchButton: NSPanel?
    var dashSub: AnyCancellable?

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.imageHugsTitle = true
        statusItem.button?.action = #selector(toggleDashboard)
        statusItem.button?.target = self
        updateIcon()
        makeNotchButton()
        dashSub = dashboard.objectWillChange.sink { [weak self] in DispatchQueue.main.async { self?.placeDashboard() } }
        iterm.onDenied = { [weak self] denied in
            guard let self, self.dashboard.accessDenied != denied else { return }
            self.dashboard.accessDenied = denied
            self.updateIcon()
        }

        if !FileManager.default.fileExists(atPath: patternsFile.path) {
            try? FileManager.default.createDirectory(at: patternsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            let header = "# One regex per line, matched against the last line of each iTerm2 tab.\n# It only fires if nothing was typed after the match.\n"
            try? (header + defaultPatterns.joined(separator: "\n") + "\n").write(to: patternsFile, atomically: true, encoding: .utf8)
        }

        DistributedNotificationCenter.default().addObserver(self, selector: #selector(hook(_:)), name: hookNote, object: nil)
        #if DEBUG
        // Test builds only (make debug): lets a script click cards. Never in a normal build, since any app
        // on the Mac could post this and type into your terminal.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("dev.notiapp.debug"), object: nil, queue: .main) { [weak self] n in
            guard let self, let id = n.object as? String, let what = n.userInfo?["do"] as? String else { return }
            if self.cards[id] == nil { self.pick(id) }
            let parts = what.split(separator: ":", maxSplits: 1).map(String.init)
            let a: Answer? = switch parts[0] {
            case "pick": .pick(Int(parts[1]) ?? 0)
            case "reply": .reply(parts[1])
            case "next": .nextTab
            case "submit": .submit
            default: nil
            }
            log("debug \(id) \(what)")
            if let a { self.answer(id, a) }
        }
        #endif
        try? SMAppService.mainApp.register() // start at login
        hotKey = HotKey(keyCode: 49, modifiers: controlKey | optionKey) { [weak self] in self?.summon() } // ⌃⌥Space
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refreshUsage() }
        refreshUsage()
    }

    // MARK: watching

    // Reads every tab in the background, then updates cards here on the main thread
    func tick() {
        guard !reading else { return }
        reading = true
        // ponytail: re-reads a tiny file every tick, cache by mtime if it ever shows up in a profile
        patterns = loadPatterns((try? String(contentsOf: patternsFile, encoding: .utf8)) ?? "")
        let started = Date()
        iterm.readAll { [weak self] result in
            self?.reading = false
            if let result { self?.apply(front: result.front, sessions: result.sessions, readAt: started) }
        }
    }

    func apply(front: String, sessions: [Session], readAt: Date) {
        self.front = front
        known = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var tabs: [TabStatus] = []

        for s in sessions {
            if changed[s.id]?.tail != s.tail { changed[s.id] = (s.tail, Date()) }
            let quiet = Date().timeIntervalSince(changed[s.id]!.at)
            let found = detectPrompt(screen: s.tail, patterns: patterns, quietFor: quiet)
            if let p = found ?? cards[s.id]?.prompt {
                tabs.append(TabStatus(id: s.id, name: s.name, state: .waiting, note: p.line.isEmpty ? "Waiting for you" : p.line))
            } else if let busy = claudeActivity(s.tail) {
                tabs.append(TabStatus(id: s.id, name: s.name, state: .working, note: busy))
            } else if s.name.localizedCaseInsensitiveContains("claude") {
                tabs.append(TabStatus(id: s.id, name: s.name, state: .idle, note: "Idle"))
            }

            if found == nil {
                hidden.remove(s.id)
                // the hook fires just before Claude draws its dialog, so give the detail a moment to find its prompt
                if let d = details[s.id], Date().timeIntervalSince(d.at) > 5 { details[s.id] = nil }
            }

            // mid-walk the screen shows the cursor halfway there, don't mirror that
            // A read takes ~0.5s, so one that started before our keys landed shows the old screen.
            // Mirroring it would flash your ticks away for a moment, or bring back a card you just answered.
            // Claude also needs a moment to redraw after the keys arrive, hence the extra 0.4s.
            let typing = inFlight[s.id, default: 0] > 0 || (typedAt[s.id] ?? .distantPast).addingTimeInterval(0.4) > readAt
            if let card = cards[s.id] {
                if card.failed, card.prompt != found { card.failed = false } // something got through after all
                if typing { continue }
                if let found {
                    // Live mirror: a ticked box, a moved cursor or the next question all land on the same card
                    if found != card.prompt {
                        log("mirror \(s.id) \(found.line.prefix(40).debugDescription) ticks \(found.rows.compactMap(\.checked)) cursor \(found.cursor)")
                        card.prompt = found
                    }
                    card.snapshot = s.tail
                } else if !(card.prompt.kind == .idle && s.tail == card.snapshot) {
                    close(s.id, "prompt gone from screen") // answered, here or in the terminal
                    continue
                }
                // Clicked but nothing changed on screen for a while, so let you try again
                if card.sent != nil, Date().timeIntervalSince(card.sentAt) > 4 { card.sent = nil }
                // still unanswered after 2 minutes, so nudge once more
                if !card.repinged, !dashboard.paused, Date().timeIntervalSince(card.since) > 120 {
                    card.repinged = true
                    NSSound(named: "Glass")?.play()
                    panels[s.id].map(shake)
                }
            } else if let found, !typing, !dashboard.paused, !hidden.contains(s.id), !isLooking(at: s.id, front: front) {
                open(s, found, detail: details.removeValue(forKey: s.id))
            }
        }
        // tabs that were closed take their cards with them
        for id in cards.keys where !sessions.contains(where: { $0.id == id }) { close(id, "tab closed") }
        relayout()
        // waiting ones first, then working, then idle
        tabs.sort { rank($0.state) < rank($1.state) }
        if tabs != dashboard.tabs { dashboard.tabs = tabs }
        updateIcon()
    }

    private func rank(_ s: TabState) -> Int { s == .waiting ? 0 : s == .working ? 1 : 2 }

    // Bell with a count of waiting prompts, or a crossed out bell while paused.
    // Template images and the menu bar font, so it tints like the system icons in light, dark and on any wallpaper.
    func updateIcon() {
        if dashboard.pausedUntil != nil, !dashboard.paused { dashboard.pausedUntil = nil } // the hour is up
        let waiting = dashboard.waiting
        let symbol = dashboard.paused || dashboard.accessDenied ? "bell.slash" : waiting > 0 ? "bell.fill" : "bell"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "NotiApp")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        image?.isTemplate = true
        guard let button = statusItem.button else { return }
        button.image = image
        button.attributedTitle = NSAttributedString(string: waiting > 0 ? "\(waiting)" : "", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
            .baselineOffset: 0.5,
        ])
        button.setAccessibilityLabel(waiting > 0 ? "NotiApp, \(waiting) waiting" : "NotiApp")
    }

    // The dashboard drops out of the notch, the same way cards do, and folds back in when you click away or press Esc
    @objc func toggleDashboard() {
        if dashPanel != nil { return hideDashboard() }
        // clicking the bell or notch to close it first takes focus away, which already closed it a moment ago
        guard Date().timeIntervalSince(dashClosedAt) > 0.3 else { return }
        if Date().timeIntervalSince(dashboard.usageAt) > 60 { refreshUsage() }
        dashboard.notch = notchSize
        dashboard.leaving = false
        let host = NSHostingView(rootView: DashboardView(
            model: dashboard,
            pick: { [weak self] id in self?.hideDashboard(); self?.pick(id) },
            pause: { [weak self] until in self?.dashboard.pausedUntil = until; self?.updateIcon() },
            editPatterns: { [weak self] in self?.hideDashboard(); self?.editPatterns() },
            openSettings: { [weak self] in self?.hideDashboard(); self?.openAutomationSettings() }))
        host.sizingOptions = [.intrinsicContentSize] // still reports its size, but leaves placing the window to us, pinned to the top of the screen
        let panel = NotchPanel(host, raised: 4) // above any card sitting in the notch
        panel.dismiss = { [weak self] in self?.hideDashboard() }
        dashPanel = panel
        placeDashboard()
        panel.makeKeyAndOrderFront(nil)
    }

    func hideDashboard() {
        guard let panel = dashPanel else { return }
        dashPanel = nil
        dashClosedAt = Date()
        dashboard.leaving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { panel.close() }
    }

    // usage loading in or a tab starting work changes its height, so this runs again after every dashboard update
    func placeDashboard() {
        guard let panel = dashPanel, let host = panel.contentView, let screen = notchScreen else { return }
        panel.setContentSize(host.fittingSize)
        panel.setFrameOrigin(NSPoint(x: screen.frame.midX - panel.frame.width / 2, y: screen.frame.maxY - panel.frame.height))
    }

    // An invisible button over the notch itself, so clicking the notch opens the dashboard.
    // Nothing is drawn: a fully clear window lets clicks fall through, so it's filled at 0.1% opacity,
    // which no one can see but still counts as something to click. It stops short of the notch's edges too.
    func makeNotchButton() {
        let size = notchSize
        guard size.width > 0, let screen = notchScreen else { return }
        let view = ClickView { [weak self] in self?.toggleDashboard() }
        let panel = NotchPanel(view, raised: 2)
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.001)
        panel.ignoresMouseEvents = false // said out loud, so the clear parts take clicks too
        let w = size.width - 24, h = size.height - 12
        panel.setFrame(NSRect(x: screen.frame.midX - w / 2, y: screen.frame.maxY - h, width: w, height: h), display: false)
        panel.orderFrontRegardless()
        notchButton = panel
    }

    // Plan limits for Codex and Command Code, every 5 minutes and whenever the dashboard opens after a minute
    func refreshUsage() {
        dashboard.usageAt = Date()
        UsageFetcher.fetchAll { [weak self] usage in
            log("usage " + usage.map { "\($0.id): \($0.error ?? $0.limits.map { "\($0.label) \(Int($0.used * 100))%" }.joined(separator: ", "))" }.joined(separator: " · "))
            guard let self, usage != self.dashboard.usage else { return }
            self.dashboard.usage = usage
        }
    }

    // A row in the dashboard: answer it on its card if it's waiting, otherwise jump to the tab
    func pick(_ id: String) {
        if cards[id] == nil, let s = known[id],
           let found = detectPrompt(screen: s.tail, patterns: patterns, quietFor: .infinity) {
            hidden.remove(id)
            open(s, found, detail: details.removeValue(forKey: id))
        }
        guard cards[id] != nil else { return focus(id) }
        for (other, c) in cards { c.keyboard = other == id }
        panels[id]?.makeKeyAndOrderFront(nil)
    }

    // a little side to side wiggle, like a wrong password field
    func shake(_ panel: NSWindow) {
        let origin = panel.frame.origin
        let anim = CAKeyframeAnimation()
        anim.values = [0, -8, 8, -6, 6, -3, 3, 0].map { NSValue(point: NSPoint(x: origin.x + $0, y: origin.y)) }
        anim.duration = 0.4
        panel.animations = ["frameOrigin": anim]
        panel.animator().setFrameOrigin(origin)
    }

    // You count as looking if this exact tab is in front and you touched the keyboard or mouse in the last minute
    func isLooking(at id: String, front: String) -> Bool {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ITerm.bundleID && front == id && idle < 60
    }

    @objc func hook(_ note: Notification) {
        guard let id = note.object as? String, let info = note.userInfo as? [String: String] else { return }
        if info["kind"] == "detail" {
            let d = Detail(title: info["title"] ?? "", body: info["body"] ?? "",
                           diff: (info["diff"] ?? "").split(separator: "\n").map(String.init))
            if let card = cards[id] { card.detail = d } else { details[id] = d }
            return
        }
        // Claude finished and is sitting at its input box
        guard cards[id] == nil, !dashboard.paused, let s = known[id], !isLooking(at: id, front: front) else { return }
        open(s, Prompt(kind: .idle, line: info["body"] ?? "Claude is waiting for your input"), detail: nil)
        relayout()
    }

    // MARK: cards

    func open(_ s: Session, _ prompt: Prompt, detail: Detail?) {
        log("open \(s.id) \(prompt.kind) \(prompt.line.debugDescription) rows \(prompt.rows.map(\.label)) cursor \(prompt.cursor)")
        let card = CardModel(session: s.id, title: s.name, prompt: prompt, detail: detail)
        card.snapshot = s.tail
        // decided before the card is drawn, so it opens already in its notch shape
        card.docked = order.isEmpty
        card.notch = notchSize
        let id = s.id
        let panel = CardPanel(CardView(model: card) { [weak self] action in
            DispatchQueue.main.async { self?.handle(id, action) } // let the button finish before its card changes
        })
        cards[id] = card
        panels[id] = panel
        order.append(id)
        relayout()
        panel.orderFrontRegardless()
        NSSound(named: "Glass")?.play()
    }

    var notchScreen: NSScreen? { NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main }

    // 185 x 32 on a 14" MacBook Pro. Screens without one get a notch-sized starting point anyway, so cards still grow from the top middle.
    var notchSize: CGSize {
        guard let s = notchScreen, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea else { return .zero }
        return CGSize(width: r.minX - l.maxX, height: s.safeAreaInsets.top)
    }

    // The first card hangs from the notch and the rest line up underneath it.
    // Prefers the MacBook's own screen; on a plain external display it hangs from the middle of the menu bar instead.
    func relayout() {
        guard let screen = notchScreen else { return }
        var top = screen.frame.maxY
        for (i, id) in order.enumerated() {
            guard let panel = panels[id], let card = cards[id] else { continue }
            if card.docked != (i == 0) { card.docked = i == 0 }
            if card.notch != notchSize { card.notch = notchSize }
            panel.fit()
            panel.setFrameOrigin(NSPoint(x: screen.frame.midX - panel.frame.width / 2, y: top - panel.frame.height))
            top -= panel.frame.height // each card already has a see-through margin below it
        }
    }

    func close(_ id: String, _ why: String) {
        if cards[id] != nil { log("close \(id) \(why)") }
        cards.removeValue(forKey: id)?.leaving = true
        if let panel = panels.removeValue(forKey: id) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { panel.close() } // once it has folded away
        }
        order.removeAll { $0 == id }
        relayout()
    }

    func handle(_ id: String, _ action: CardAction) {
        switch action {
        case .close:
            hidden.insert(id)
            close(id, "you hid it")
        case .open:
            hidden.insert(id)
            close(id, "opened in iTerm2")
            focus(id)
        case .release:
            release(id)
        case .answer(let a):
            answer(id, a)
        }
    }

    // ⌃⌥Space: put the keyboard on the top card, pressing it again moves on to the next card
    func summon() {
        guard !order.isEmpty else { return NSSound.beep() }
        let current = order.firstIndex { cards[$0]?.keyboard == true }
        let next = order[current.map { ($0 + 1) % order.count } ?? 0]
        for (id, card) in cards { card.keyboard = id == next }
        panels[next]?.makeKeyAndOrderFront(nil)
    }

    // Give the keyboard back to whatever app you were in. The card stays put.
    func release(_ id: String) {
        cards[id]?.keyboard = false
        guard let panel = panels[id] else { return }
        panel.orderOut(nil) // the app you were in gets its key window back
        panel.orderFrontRegardless()
    }

    func answer(_ id: String, _ a: Answer) {
        guard let card = cards[id], let where_ = known[id] else { return }
        let expected = card.prompt, snapshot = card.snapshot, pats = patterns
        // if an earlier click's keys are still landing, the screen is half updated, so trust the card
        let trustCard = inFlight[id, default: 0] > 0

        // answer on the card right away, the terminal catches up in the background
        if case .pick(let i) = a, expected.rows[i].checked != nil {
            // ticking a box: show it now and keep the card live, you're probably ticking another
            card.prompt.rows[i].checked?.toggle()
            card.prompt.cursor = i
        } else if expected.tabs.isEmpty, !a.movesBetweenQuestions {
            // a final answer: the card folds away right now and the keys follow a moment later.
            // If they don't make it, the card comes back saying so.
            close(id, "answered")
        } else {
            // more questions to come, so dim the card with a "Sent" badge until the next one shows up
            card.sent = card.prompt
            card.sentAt = Date()
        }

        inFlight[id, default: 0] += 1
        iterm.queue.async { [self] in
            var prompt = expected
            if !trustCard {
                // Re-read the screen first. If the prompt is gone, a late click must not type into whatever is there now.
                let tail = iterm.readTail(where_)
                let now = detectPrompt(screen: tail, patterns: pats, quietFor: .infinity)
                let still = expected.kind == .idle ? tail == snapshot : now.map { $0.kind == expected.kind && $0.line == expected.line } ?? false
                guard still else {
                    log("answer \(id) \(a) dropped, screen now shows \(String(describing: now))")
                    return DispatchQueue.main.async { self.inFlight[id, default: 1] -= 1; self.close(id, "prompt changed before the click landed") }
                }
                if expected.kind != .idle, let now { prompt = now } // fresh cursor, in case you moved it in the terminal
            }
            let (keys, gap) = keys(for: a, in: prompt)
            let ok = iterm.send(where_, keys, gap: gap)
            log("answer \(id) \(a) cursor \(prompt.cursor) keys \(keys) trusted card: \(trustCard) sent: \(ok)")

            // Watch just this tab (~30ms a look, vs ~500ms to read every tab) until Claude has redrawn:
            // the screen changed and looks the same on the next look. Then show it on the card right away.
            var fresh: (tail: String, prompt: Prompt?)?
            var last: Prompt?? = .none
            for _ in 0..<25 where ok {
                let tail = iterm.readTail(where_)
                let now = detectPrompt(screen: tail, patterns: pats, quietFor: .infinity)
                if now != prompt, case .some(let previous) = last, previous == now { fresh = (tail, now); break }
                last = .some(now)
                Thread.sleep(forTimeInterval: 0.06)
            }

            DispatchQueue.main.async {
                self.inFlight[id, default: 1] -= 1
                self.typedAt[id] = Date()
                if !ok, self.cards[id] == nil, let s = self.known[id] { self.open(s, expected, detail: nil) }
                guard let card = self.cards[id] else { return }
                if !ok {
                    // undo the optimistic tick or Sent badge and say so, instead of pretending it worked
                    card.prompt = expected
                    card.sent = nil
                    card.failed = true
                } else if let fresh, self.inFlight[id, default: 0] == 0 {
                    if let p = fresh.prompt {
                        if p != card.prompt {
                            log("mirror \(id) \(p.line.prefix(40).debugDescription) ticks \(p.rows.compactMap(\.checked)) cursor \(p.cursor) (fast)")
                            card.prompt = p
                        }
                        card.snapshot = fresh.tail
                    } else if card.prompt.kind != .idle {
                        self.close(id, "prompt gone from screen")
                    }
                    self.relayout()
                }
            }
        }
    }

    func focus(_ id: String) {
        known[id].map(iterm.focus)
    }

    func openAutomationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }

    func editPatterns() {
        NSWorkspace.shared.open(patternsFile)
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.run()

final class ClickView: NSView {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { action() }
}
