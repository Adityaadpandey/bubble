import AppKit
import ServiceManagement
import Carbon
import SwiftUI

let iTermID = "com.googlecode.iterm2"
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

struct Session { let id, name, tail: String }

final class App: NSObject, NSApplicationDelegate {
    var cards: [String: CardModel] = [:]      // one live card per iTerm2 session that's waiting on you
    var panels: [String: CardPanel] = [:]
    var order: [String] = []                  // oldest card on top, newer ones stack below it
    var hidden: Set<String> = []              // you pressed ✕, stays hidden until that prompt is gone
    var details: [String: Detail] = [:]       // latest tool call per session, from the hook
    var patterns: [NSRegularExpression] = []
    var hotKey: HotKey?
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let dashboard = Dashboard()
    let popover = NSPopover()

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: DashboardView(
            model: dashboard,
            pick: { [weak self] id in self?.popover.performClose(nil); self?.pick(id) },
            pause: { [weak self] until in self?.dashboard.pausedUntil = until; self?.updateIcon() },
            editPatterns: { [weak self] in self?.editPatterns() },
            openSettings: { [weak self] in self?.openAutomationSettings() }))
        updateIcon()

        if !FileManager.default.fileExists(atPath: patternsFile.path) {
            try? FileManager.default.createDirectory(at: patternsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            let header = "# One regex per line, matched against the last line of each iTerm2 tab.\n# It only fires if nothing was typed after the match.\n"
            try? (header + defaultPatterns.joined(separator: "\n") + "\n").write(to: patternsFile, atomically: true, encoding: .utf8)
        }

        DistributedNotificationCenter.default().addObserver(self, selector: #selector(hook(_:)), name: hookNote, object: nil)
        try? SMAppService.mainApp.register() // start at login
        hotKey = HotKey(keyCode: 49, modifiers: controlKey | optionKey) { [weak self] in self?.summon() } // ⌃⌥Space
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    // MARK: watching

    func tick() {
        // ponytail: re-reads a tiny file every tick, cache by mtime if it ever shows up in a profile
        patterns = loadPatterns((try? String(contentsOf: patternsFile, encoding: .utf8)) ?? "")
        guard let (front, sessions) = readSessions() else { return }
        var tabs: [TabStatus] = []

        for s in sessions {
            let found = detectPrompt(screen: s.tail, patterns: patterns)
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

            if let card = cards[s.id] {
                if let found {
                    // Live mirror: a ticked box, a moved cursor or the next question all land on the same card
                    if found != card.prompt { card.prompt = found }
                    card.snapshot = s.tail
                } else if !(card.prompt.kind == .idle && s.tail == card.snapshot) {
                    close(s.id) // answered, here or in the terminal
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
            } else if let found, !dashboard.paused, !hidden.contains(s.id), !isLooking(at: s.id, front: front) {
                open(s, found, detail: details.removeValue(forKey: s.id))
            }
        }
        // tabs that were closed take their cards with them
        for id in cards.keys where !sessions.contains(where: { $0.id == id }) { close(id) }
        relayout()
        // waiting ones first, then working, then idle
        tabs.sort { rank($0.state) < rank($1.state) }
        if tabs != dashboard.tabs { dashboard.tabs = tabs }
        updateIcon()
    }

    private func rank(_ s: TabState) -> Int { s == .waiting ? 0 : s == .working ? 1 : 2 }

    // Bell with a count of waiting prompts, or a crossed out bell while paused
    func updateIcon() {
        if dashboard.pausedUntil != nil, !dashboard.paused { dashboard.pausedUntil = nil } // the hour is up
        let symbol = dashboard.paused || dashboard.accessDenied ? "bell.slash" : dashboard.waiting > 0 ? "bell.badge.fill" : "bell"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "NotiApp")
        statusItem.button?.title = dashboard.waiting > 0 ? " \(dashboard.waiting)" : ""
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) } else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }

    // A row in the dashboard: answer it on its card if it's waiting, otherwise jump to the tab
    func pick(_ id: String) {
        if cards[id] == nil, let s = readSessions()?.1.first(where: { $0.id == id }),
           let found = detectPrompt(screen: s.tail, patterns: patterns) {
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
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == iTermID && front == id && idle < 60
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
        guard cards[id] == nil, !dashboard.paused, let (front, sessions) = readSessions(),
              let s = sessions.first(where: { $0.id == id }), !isLooking(at: id, front: front) else { return }
        open(s, Prompt(kind: .idle, line: info["body"] ?? "Claude is waiting for your input"), detail: nil)
        relayout()
    }

    // MARK: cards

    func open(_ s: Session, _ prompt: Prompt, detail: Detail?) {
        let card = CardModel(session: s.id, title: s.name, prompt: prompt, detail: detail)
        card.snapshot = s.tail
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

    func relayout() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        var top = screen.maxY - 12
        for id in order {
            guard let panel = panels[id] else { continue }
            panel.fit()
            panel.setFrameOrigin(NSPoint(x: screen.maxX - panel.frame.width - 12, y: top - panel.frame.height))
            top -= panel.frame.height + 10
        }
    }

    func close(_ id: String) {
        cards[id] = nil
        panels.removeValue(forKey: id)?.close()
        order.removeAll { $0 == id }
        relayout()
    }

    func handle(_ id: String, _ action: CardAction) {
        switch action {
        case .close:
            hidden.insert(id)
            close(id)
        case .open:
            hidden.insert(id)
            close(id)
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
        guard let card = cards[id], let s = readSessions()?.1.first(where: { $0.id == id }) else { return }
        // Re-read the screen first. If the prompt is gone, a late click must not type into whatever is there now.
        let now = detectPrompt(screen: s.tail, patterns: patterns)
        if card.prompt.kind == .idle {
            guard s.tail == card.snapshot else { return close(id) }
        } else {
            guard let now, now.kind == card.prompt.kind, now.line == card.prompt.line else { return close(id) }
            card.prompt = now // fresh cursor position, in case you moved it in the terminal meanwhile
        }
        let (keys, gap) = keys(for: a, in: card.prompt)
        press(id, keys, gap: gap)
        // dim the card with a "Sent" badge until the screen moves on, so it never looks like it's asking again
        card.sent = card.prompt
        card.sentAt = Date()
    }

    // MARK: iTerm2 via AppleScript

    func readSessions() -> (String, [Session])? {
        // `tell application "iTerm2"` would launch it, so only talk to it when it's already up
        guard NSRunningApplication.runningApplications(withBundleIdentifier: iTermID).first != nil else { return nil }
        guard let r = run("""
            set out to {}
            set frontID to ""
            try
                set frontID to unique id of current session of current tab of current window
            end try
            set AppleScript's text item delimiters to linefeed
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        set c to contents of s
                        set n to count of paragraphs of c
                        if n > 50 then set n to 50
                        set tailText to ""
                        if n > 0 then set tailText to (paragraphs -n thru -1 of c) as text
                        set end of out to {unique id of s, name of s, tailText}
                    end repeat
                end repeat
            end repeat
            return {frontID, out}
            """) else { return nil }
        let list = r.atIndex(2)!
        let sessions = (0..<list.numberOfItems).compactMap { i -> Session? in
            let item = list.atIndex(i + 1)!
            guard let id = item.atIndex(1)?.stringValue else { return nil }
            return Session(id: id, name: item.atIndex(2)?.stringValue ?? "iTerm2", tail: item.atIndex(3)?.stringValue ?? "")
        }
        return (r.atIndex(1)?.stringValue ?? "", sessions)
    }

    // Sends each chunk as its own keypress, a little apart, so TUIs like Claude don't see
    // "↓ ↓ Enter" glued together as one unknown key
    func press(_ id: String, _ keys: [String], gap: Double) {
        for (i, key) in keys.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + gap * Double(i)) {
                self.onSession(id, "tell s to write text \(appleScriptString(key)) newline NO")
            }
        }
    }

    func focus(_ id: String) {
        onSession(id, "tell w to select\ntell t to select\ntell s to select\nactivate")
    }

    func onSession(_ id: String, _ body: String) {
        guard id.range(of: #"^[A-F0-9-]+$"#, options: .regularExpression) != nil else { return }
        _ = run("""
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if unique id of s is "\(id)" then
                            \(body)
                            return
                        end if
                    end repeat
                end repeat
            end repeat
            """)
    }

    func run(_ body: String) -> NSAppleEventDescriptor? {
        var err: NSDictionary?
        let result = NSAppleScript(source: "tell application \"iTerm2\"\n\(body)\nend tell")?.executeAndReturnError(&err)
        // -1743: you said no (or haven't been asked yet) to letting NotiApp control iTerm2
        let denied = (err?[NSAppleScript.errorNumber] as? Int) == -1743
        if dashboard.accessDenied != denied { dashboard.accessDenied = denied }
        return err == nil ? result : nil
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
