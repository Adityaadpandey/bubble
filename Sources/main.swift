import AppKit
import ServiceManagement
import UserNotifications

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

final class App: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    struct Pending { let prompt: Prompt; let snapshot: String }

    var pending: [String: Pending] = [:]       // one open notification per iTerm2 session
    var claudeDetail: [String: String] = [:]   // latest "Bash: npm install" per session, from the hook
    var patterns: [NSRegularExpression] = []
    let center = UNUserNotificationCenter.current()
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

        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let reply = UNTextInputNotificationAction(identifier: "reply", title: "Reply…", options: [], textInputButtonTitle: "Send", textInputPlaceholder: "Type your answer")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "yesno", actions: [
                UNNotificationAction(identifier: "approve", title: "Approve"),
                UNNotificationAction(identifier: "deny", title: "Deny", options: .destructive),
                reply,
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: "reply", actions: [reply], intentIdentifiers: []),
        ])

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
                // answered in the terminal (or it moved on), so pull the stale notification
                if !stillThere(p, tail: s.tail, found: found) { clear(s.id) }
                continue
            }
            guard let found, !isLooking(at: s.id, front: front) else { continue }
            let body = found.kind == .claude ? (claudeDetail.removeValue(forKey: s.id) ?? found.line) : found.line
            pending[s.id] = Pending(prompt: found, snapshot: s.tail)
            notify(s.id, title: s.name, body: body, category: "yesno")
        }
    }

    func stillThere(_ p: Pending, tail: String, found: Prompt?) -> Bool {
        // Claude idle has nothing to match on, so "still waiting" means the screen hasn't changed at all
        p.prompt.kind == .idle ? tail == p.snapshot : found == p.prompt
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
        pending[id] = Pending(prompt: Prompt(kind: .idle, line: text), snapshot: s.tail)
        notify(id, title: s.name, body: text, category: "reply")
    }

    // MARK: notifications

    func notify(_ id: String, title: String, body: String, category: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        c.categoryIdentifier = category
        // the session id doubles as the notification id, so each tab has at most one
        center.add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    func clear(_ id: String) {
        pending[id] = nil
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void) {
        let id = r.notification.request.identifier
        let action = r.actionIdentifier
        let text = (r as? UNTextInputNotificationResponse)?.userText ?? ""
        DispatchQueue.main.async {
            defer { done() }
            if action == UNNotificationDefaultActionIdentifier { return self.focus(id) }
            guard let p = self.pending[id] else { return }
            self.clear(id)

            // Re-read the screen first. If the prompt is gone, a late click must not type into whatever is there now.
            guard let s = self.readSessions()?.1.first(where: { $0.id == id }),
                  self.stillThere(p, tail: s.tail, found: detectPrompt(screen: s.tail, patterns: self.patterns)) else { return }

            switch (action, p.prompt.kind) {
            case ("approve", .claude): self.type(id, "", enter: true)       // "1. Yes" is selected by default
            case ("deny", .claude): self.type(id, "\u{1b}", enter: false)   // Esc = "No, tell Claude what to do"
            case ("approve", _): self.type(id, "y", enter: true)
            case ("deny", _): self.type(id, "n", enter: true)
            case ("reply", .claude):
                // decline the dialog, then give Claude your note once its input box is back
                self.type(id, "\u{1b}", enter: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.type(id, text, enter: true) }
            case ("reply", _): self.type(id, text, enter: true)
            default: break
            }
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

    func type(_ id: String, _ text: String, enter: Bool) {
        // escape for an AppleScript string literal, and pass Esc through as `character id 27`
        let literal = text == "\u{1b}" ? "(character id 27)"
            : "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        onSession(id, "tell s to write text \(literal) newline \(enter ? "YES" : "NO")")
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
