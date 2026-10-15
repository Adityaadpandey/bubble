import AppKit
import ServiceManagement

let iTermID = "com.googlecode.iterm2"
let hookNote = Notification.Name("dev.notiapp.hook")
let patternsFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/notiapp/patterns.txt")

// Hook mode: Claude Code runs `NotiApp hook` with the event JSON on stdin.
// We boil it down to one line, hand it to the running app and exit right away,
// so Claude never waits on us and shows its own prompt as usual.
if CommandLine.arguments.dropFirst().first == "hook" {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    // ITERM_SESSION_ID looks like "w0t5p0:3B3A957A-...", the part after the colon is iTerm2's session id
    guard let session = ProcessInfo.processInfo.environment["ITERM_SESSION_ID"]?.split(separator: ":").last else { exit(0) }

    var info: [String: String] = [:]
    switch obj["hook_event_name"] as? String {
    case "PermissionRequest":
        // e.g. "Bash: npm install left-pad", shown as the body once the dialog appears on screen
        let input = obj["tool_input"] as? [String: Any] ?? [:]
        let detail = ["command", "file_path", "url", "pattern"].lazy.compactMap { input[$0] as? String }.first ?? ""
        info = ["kind": "detail", "text": "\(obj["tool_name"] as? String ?? "Tool"): \(detail)"]
    case "Notification":
        let message = obj["message"] as? String ?? ""
        guard message.contains("waiting for your input") else { exit(0) } // permission ones are caught on screen
        info = ["kind": "idle", "text": message]
    default:
        exit(0)
    }
    info["text"] = String(info["text"]!.prefix(200))
    DistributedNotificationCenter.default().postNotificationName(hookNote, object: String(session), userInfo: info, deliverImmediately: true)
    exit(0)
}

struct Session { let id, name, tail: String }

final class App: NSObject, NSApplicationDelegate {
    struct Pending { let prompt: Prompt; let snapshot: String }

    var pending: [String: Pending] = [:]       // one waiting prompt per iTerm2 session
    var claudeDetail: [String: String] = [:]   // latest "Bash: npm install" per session, from the hook
    var patterns: [NSRegularExpression] = []
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let warning = NSMenuItem(title: "", action: #selector(openAutomationSettings), keyEquivalent: "")

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem.button?.image = NSImage(systemSymbolName: "bell.badge", accessibilityDescription: "NotiApp")
        let menu = NSMenu()
        warning.isHidden = true
        warning.target = self
        menu.addItem(warning)
        menu.addItem(withTitle: "Edit Prompt Patterns…", action: #selector(editPatterns), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit NotiApp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        if !FileManager.default.fileExists(atPath: patternsFile.path) {
            try? FileManager.default.createDirectory(at: patternsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            let header = "# One regex per line, matched against the last line of each iTerm2 tab.\n# It only fires if nothing was typed after the match.\n"
            try? (header + defaultPatterns.joined(separator: "\n") + "\n").write(to: patternsFile, atomically: true, encoding: .utf8)
        }

        DistributedNotificationCenter.default().addObserver(self, selector: #selector(hook(_:)), name: hookNote, object: nil)
        try? SMAppService.mainApp.register() // start at login
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    // MARK: watching

    func tick() {
        // ponytail: re-reads a tiny file every tick, cache by mtime if it ever shows up in a profile
        patterns = loadPatterns((try? String(contentsOf: patternsFile, encoding: .utf8)) ?? "")
        guard let (front, sessions) = readSessions() else { return }

        for s in sessions {
            let found = detectPrompt(screen: s.tail, patterns: patterns)
            if let p = pending[s.id] {
                // answered in the terminal (or it moved on), so pull the stale card
                if !stillThere(p, tail: s.tail, found: found) { clear(s.id) }
                continue
            }
            guard let found, !isLooking(at: s.id, front: front) else { continue }
            pending[s.id] = Pending(prompt: found, snapshot: s.tail)
            // the hook told us what Claude wants to run, e.g. "Bash: npm install left-pad"
            let detail = found.kind == .claude ? claudeDetail.removeValue(forKey: s.id) : nil
            show(s.id, title: s.name, detail: detail, prompt: found)
        }
    }

    func stillThere(_ p: Pending, tail: String, found: Prompt?) -> Bool {
        // Claude idle has nothing to match on, so "still waiting" means the screen hasn't changed at all
        p.prompt.kind == .idle ? tail == p.snapshot : p.prompt.sameAs(found)
    }

    // You count as looking if this exact tab is in front and you touched the keyboard or mouse in the last minute
    func isLooking(at id: String, front: String) -> Bool {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == iTermID && front == id && idle < 60
    }

    @objc func hook(_ note: Notification) {
        guard let id = note.object as? String, let kind = note.userInfo?["kind"] as? String,
              let text = note.userInfo?["text"] as? String else { return }
        if kind == "detail" { claudeDetail[id] = text; return }

        guard pending[id] == nil, let (front, sessions) = readSessions(),
              let s = sessions.first(where: { $0.id == id }), !isLooking(at: id, front: front) else { return }
        let prompt = Prompt(kind: .idle, line: text)
        pending[id] = Pending(prompt: prompt, snapshot: s.tail)
        show(id, title: s.name, detail: nil, prompt: prompt)
    }

    // MARK: popups

    var panels: [String: PromptPanel] = [:]
    var order: [String] = [] // oldest card on top, newer ones stack below it

    func show(_ id: String, title: String, detail: String?, prompt: Prompt) {
        let choices: [Choice]
        switch prompt.kind {
        case .claude:
            // a button per menu choice, e.g. "1. Yes" / "2. Yes, and don't ask again" / "3. No".
            // Claude's own "Type something." and "Chat about this" are what the Reply box is for.
            choices = prompt.options.enumerated()
                .filter { !["Type something.", "Chat about this"].contains($0.element) }
                .map { Choice(id: "opt-\($0.offset + 1)", label: "\($0.offset + 1). \($0.element)") }
        case .yesNo:
            choices = [Choice(id: "approve", label: "Yes"), Choice(id: "deny", label: "No")]
        case .idle:
            choices = []
        }
        dismiss(id)
        let card = PromptCard(title: title, detail: detail, question: prompt.line.isEmpty ? "Waiting for you" : prompt.line,
                              choices: choices) { [weak self] action, text in
            DispatchQueue.main.async { self?.handle(id, action, text) } // let the button finish before its card closes
        }
        let panel = PromptPanel(card)
        panels[id] = panel
        order.append(id)
        layout()
        panel.orderFrontRegardless()
        NSSound(named: "Glass")?.play()
    }

    func layout() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        var top = screen.maxY - 12
        for id in order {
            guard let p = panels[id] else { continue }
            p.setFrameOrigin(NSPoint(x: screen.maxX - p.frame.width - 12, y: top - p.frame.height))
            top -= p.frame.height + 10
        }
    }

    // Hides the card but keeps the prompt pending, so ✕ doesn't make it pop right back up
    func dismiss(_ id: String) {
        panels.removeValue(forKey: id)?.close()
        order.removeAll { $0 == id }
        layout()
    }

    func clear(_ id: String) {
        pending[id] = nil
        dismiss(id)
    }

    func handle(_ id: String, _ action: String, _ text: String) {
        if action == "close" { return dismiss(id) }
        if action == "open" { dismiss(id); return focus(id) }
        guard let p = pending[id] else { return }
        clear(id)

        // Re-read the screen first. If the prompt is gone, a late click must not type into whatever is there now.
        guard let s = readSessions()?.1.first(where: { $0.id == id }) else { return }
        let now = detectPrompt(screen: s.tail, patterns: patterns)
        guard stillThere(p, tail: s.tail, found: now) else { return }

        let down = "\u{1b}[B", up = "\u{1b}[A"
        switch action {
        case let a where a.hasPrefix("opt-"):
            // walk the ❯ from wherever it is now to the chosen option, then Enter
            let n = Int(a.dropFirst(4)) ?? 1, cursor = now?.cursor ?? 1
            press(id, Array(repeating: n > cursor ? down : up, count: abs(n - cursor)) + ["\r"])
        case "approve": press(id, ["y\r"])
        case "deny": press(id, ["n\r"])
        case "reply" where p.prompt.kind == .claude:
            // back out of the menu, then give Claude your note once its input box is back
            press(id, ["\u{1b}", text + "\r"], gap: 0.6)
        case "reply": press(id, [text + "\r"])
        default: break
        }
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
                        if n > 40 then set n to 40
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
    func press(_ id: String, _ keys: [String], gap: Double = 0.15) {
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
        warning.title = "⚠️ Allow NotiApp to control iTerm2…"
        warning.isHidden = !denied
        statusItem.button?.image = NSImage(systemSymbolName: denied ? "bell.slash" : "bell.badge", accessibilityDescription: "NotiApp")
        return err == nil ? result : nil
    }

    @objc func openAutomationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }

    @objc func editPatterns() {
        NSWorkspace.shared.open(patternsFile)
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.run()
