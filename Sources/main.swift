import AppKit
import ServiceManagement
import Carbon
import Combine
import SwiftUI

let hookNote = Notification.Name("dev.notchy.hook")
let patternsFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/notchy/patterns.txt")

// Notify mode: `Notchy notify "pi finished"` for tools that have no Claude-style hooks but can run a command when
// they're done, like pi's agent_settled event or Codex's `notify` setting. It lands as the same "waiting on you" card.
if CommandLine.arguments.dropFirst().first == "notify" {
    guard let session = hookSession(ProcessInfo.processInfo.environment) ?? controllingTTY() else { exit(0) }
    let words = CommandLine.arguments.dropFirst(2).joined(separator: " ")
    DistributedNotificationCenter.default().postNotificationName(
        hookNote, object: session, userInfo: ["kind": "idle", "body": words.isEmpty ? "Finished and waiting for you" : words,
                   "place": placeLabel(FileManager.default.currentDirectoryPath)],
        deliverImmediately: true)
    exit(0)
}

// e.g. "notiapp · main" for a folder inside a git checkout, "Downloads" for one that isn't.
// Reads .git/HEAD by hand (no git process), walking up so a subfolder like src/ still finds the repo.
// A worktree's .git is a file ("gitdir: /repo/.git/worktrees/x"), so follow that. Detached HEAD shows the short hash.
func placeLabel(_ cwd: String) -> String {
    var dir = URL(fileURLWithPath: cwd)
    let folder = dir.lastPathComponent
    for _ in 0..<12 {
        var git = dir.appendingPathComponent(".git")
        if let pointer = try? String(contentsOf: git, encoding: .utf8), pointer.hasPrefix("gitdir:") {
            git = URL(fileURLWithPath: String(pointer.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: dir)
        }
        if let head = try? String(contentsOf: git.appendingPathComponent("HEAD"), encoding: .utf8) {
            let ref = head.trimmingCharacters(in: .whitespacesAndNewlines)
            let branch = ref.hasPrefix("ref: refs/heads/") ? String(ref.dropFirst(16)) : String(ref.prefix(7))
            return "\(folder) · \(branch)"
        }
        if dir.path == "/" { break }
        dir.deleteLastPathComponent()
    }
    return folder
}

// Hook mode: Claude Code runs `Notchy hook` with the event JSON on stdin.
// We boil it down to a few strings, hand them to the running app and exit right away,
// so Claude never waits on us and shows its own prompt as usual.
if CommandLine.arguments.dropFirst().first == "hook" {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    guard let session = hookSession(ProcessInfo.processInfo.environment) ?? controllingTTY() else { exit(0) }

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
    if let cwd = obj["cwd"] as? String { info["place"] = placeLabel(cwd) }
    DistributedNotificationCenter.default().postNotificationName(hookNote, object: session, userInfo: info, deliverImmediately: true)
    exit(0)
}

// The id Notchy lists the pane Claude runs in under, from the variables its terminal sets, e.g.
//   TMUX_PANE=%5                           → "tmux:%5"
//   KITTY_WINDOW_ID=7, KITTY_LISTEN_ON=unix:/tmp/kitty-123 → "kitty:/tmp/kitty-123#7"
//   WEZTERM_PANE=4                         → "wezterm:4"
//   ITERM_SESSION_ID=w0t5p0:3B3A957A-...   → "3B3A957A-..."
// Terminal sets nothing, so it falls back to controllingTTY(). tmux comes first because it can sit inside any of the others.
func hookSession(_ env: [String: String]) -> String? {
    if let pane = env["TMUX_PANE"] { return "tmux:" + pane }
    if let id = env["KITTY_WINDOW_ID"], let socket = env["KITTY_LISTEN_ON"] {
        return "kitty:" + socket.replacingOccurrences(of: "unix:", with: "") + "#" + id
    }
    if let pane = env["WEZTERM_PANE"] { return "wezterm:" + pane }
    return env["ITERM_SESSION_ID"]?.split(separator: ":").last.map(String.init)
}

// e.g. "/dev/ttys019", or nil when nothing above us is attached to a terminal.
// Claude starts hooks detached from the terminal, so the hook itself has no tty, but Claude does:
// hook (no tty) → maybe a shell (no tty) → claude (ttys019), so walk up the parents until one has it.
func controllingTTY() -> String? {
    var pid = getpid()
    for _ in 0..<8 where pid > 1 {
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        if info.kp_eproc.e_tdev != -1, let name = devname(info.kp_eproc.e_tdev, S_IFCHR) {
            return "/dev/" + String(cString: name)
        }
        pid = info.kp_eproc.e_ppid
    }
    return nil
}

// ~/Library/Logs/Notchy.log, one line per card opened or closed and per answer sent, e.g.
//   2026-10-15T19:07:12Z answer 3B3A… pick(1) keys ["\u{1B}[B", "\r"] trusted card: false
let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Notchy.log")
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
    var cards: [String: CardModel] = [:]      // one live card per terminal tab that's waiting on you
    var panels: [String: CardPanel] = [:]
    var order: [String] = []                  // oldest card on top, newer ones stack below it
    var hidden: Set<String> = []              // you pressed ✕, stays hidden until that prompt is gone
    var details: [String: Detail] = [:]       // latest tool call per session, from the hook
    var places: [String: String] = [:]        // "folder · branch" per session, from the hook
    var changed: [String: (tail: String, at: Date)] = [:] // when each tab's screen last changed
    var inFlight: [String: Int] = [:]         // answers whose keys haven't all landed yet
    var typedAt: [String: Date] = [:]         // when our last keys finished landing in each tab
    var known: [String: Session] = [:]        // every tab as of the last read
    var fronts: [String] = []                 // the tab in front in iTerm2 and in Terminal
    var reading = false
    let terminals = Terminals()
    var patterns: [NSRegularExpression] = []
    var hotKey: HotKey?
    var settingsWindow: NSWindow?
    var appliedChoices = ""                   // Prefs.watchedChoices as of the last applyChoices()
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let dashboard = Dashboard()
    var dashPanel: NotchPanel?
    var dashClosedAt = Date.distantPast
    var notchButton: NSPanel?
    var dashSub: AnyCancellable?
    var dashByHover = false
    var hoverSince: Date?  // when the mouse came to rest on the notch
    var awaySince: Date?   // when the mouse left a dashboard that hovering opened
    var welcome: NotchPanel?  // the first-run onboarding, while it's up
    var usageWaits = false    // you skipped usage limits, so the Keychain stays untouched until you open the dashboard

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.imageHugsTitle = true
        statusItem.button?.action = #selector(toggleDashboard)
        statusItem.button?.target = self
        updateIcon()
        makeNotchButton()
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.checkHover() }
        dashSub = dashboard.objectWillChange.sink { [weak self] in DispatchQueue.main.async { self?.placeDashboard() } }
        terminals.onDenied = { [weak self] denied in
            guard let self, self.dashboard.accessDenied != denied else { return }
            self.dashboard.accessDenied = denied
            self.updateIcon()
        }

        if !FileManager.default.fileExists(atPath: patternsFile.path) {
            try? FileManager.default.createDirectory(at: patternsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            // bring your patterns along from when Notchy was called Perch, or NotiApp before that
            for name in ["perch", "notiapp"] {
                let old = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/\(name)/patterns.txt")
                if (try? FileManager.default.moveItem(at: old, to: patternsFile)) != nil { break }
            }
        }
        if !FileManager.default.fileExists(atPath: patternsFile.path) {
            let header = "# One regex per line, matched against the last line of each terminal tab.\n# It only fires if nothing was typed after the match.\n"
            try? (header + defaultPatterns.joined(separator: "\n") + "\n").write(to: patternsFile, atomically: true, encoding: .utf8)
        }

        DistributedNotificationCenter.default().addObserver(self, selector: #selector(hook(_:)), name: hookNote, object: nil)
        #if DEBUG
        // Test builds only (make debug): lets a script click cards. Never in a normal build, since any app
        // on the Mac could post this and type into your terminal.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("dev.notchy.debug"), object: nil, queue: .main) { [weak self] n in
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
        // Decided once, on the first launch of this version: already set up before onboarding existed means
        // nothing to walk you through. A brand new install stores false, so quitting halfway shows it again next time.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "onboarded") == nil { defaults.set(defaults.bool(forKey: "setUpLogin"), forKey: "onboarded") }
        // start at login the first time; after that the "Open at Login" switch in the ⋯ menu decides
        if !UserDefaults.standard.bool(forKey: "setUpLogin") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "setUpLogin")
        }
        // already connected to Claude Code but from an old copy of the app (moved, renamed): follow it quietly
        if ClaudeHooks.added && !ClaudeHooks.connected() { try? ClaudeHooks.connect() }
        dashboard.claudeConnected = ClaudeHooks.connected() || !ClaudeHooks.claudeInstalled
        Prefs.register()
        applyChoices()
        // Settings writes straight to UserDefaults, so changes to the hotkey or the usage meters are noticed here
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.applyChoices()
        }
        Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in self?.checkForUpdate() }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            guard let self, !self.usageWaits, self.welcome == nil else { return }
            self.refreshUsage()
        }
        // the first time, nothing asks macOS for anything until the onboarding gets to it
        if defaults.bool(forKey: "onboarded") { refreshUsage() } else { showWelcome() }
    }

    // Redoes whatever depends on a setting that changed: the hotkey is registered again, the usage meters fetched again.
    // Called on every UserDefaults change, so it does nothing unless one of those two actually changed.
    func applyChoices() {
        let now = Prefs.watchedChoices
        guard now != appliedChoices else { return }
        let first = appliedChoices.isEmpty
        appliedChoices = now
        hotKey = nil // the old one is unregistered as it goes
        hotKey = Shortcut.hotKey(Prefs.string("shortcut")) { [weak self] in self?.summon() }
        if !first { refreshUsage() }
        checkForUpdate()
    }

    // Once a day, and when you switch it on in Settings. Does nothing unless you've asked for it.
    func checkForUpdate() {
        guard Prefs.bool("updates.check") else { return dashboard.update = nil }
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        UpdateCheck.newer(than: current) { [weak self] found in self?.dashboard.update = found }
    }

    // MARK: watching

    // Reads every tab in the background, then updates cards here on the main thread
    func tick() {
        guard !reading, welcome == nil else { return }
        reading = true
        // ponytail: re-reads a tiny file every tick, cache by mtime if it ever shows up in a profile
        patterns = loadPatterns((try? String(contentsOf: patternsFile, encoding: .utf8)) ?? "")
        let started = Date()
        terminals.readAll { [weak self] result in
            self?.reading = false
            if let result { self?.apply(fronts: result.fronts, sessions: result.sessions, readAt: started) }
        }
    }

    func apply(fronts: [String], sessions: [Session], readAt: Date) {
        self.fronts = fronts
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
                } else if card.prompt.kind == .idle, Date().timeIntervalSince(card.since) < 3 {
                    // a tool redraws its footer just after it finishes (pi's token count, say), which isn't you moving on
                    card.snapshot = s.tail
                } else if !(card.prompt.kind == .idle && s.tail == card.snapshot) {
                    close(s.id, "prompt gone from screen") // answered, here or in the terminal
                    continue
                }
                // Clicked but nothing changed on screen for a while, so let you try again
                if card.sent != nil, Date().timeIntervalSince(card.sentAt) > 4 { card.sent = nil }
                // still unanswered after the nudge time in Settings (2 minutes unless changed), so nudge once more
                let nudge = Double(Prefs.int("nudgeSeconds"))
                if !card.repinged, !dashboard.paused, nudge > 0, Date().timeIntervalSince(card.since) > nudge {
                    card.repinged = true
                    Prefs.chime()
                    panels[s.id].map(shake)
                }
            } else if let found, !typing, !dashboard.paused, !hidden.contains(s.id), !isLooking(at: s.id) {
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
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Notchy")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        image?.isTemplate = true
        guard let button = statusItem.button else { return }
        button.image = image
        button.attributedTitle = NSAttributedString(string: waiting > 0 ? "\(waiting)" : "", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
            .baselineOffset: 0.5,
        ])
        button.setAccessibilityLabel(waiting > 0 ? "Notchy, \(waiting) waiting" : "Notchy")
    }

    // The dashboard drops out of the notch, the same way cards do, and folds back in when you click away or press Esc
    @objc func toggleDashboard() {
        if dashPanel != nil { return hideDashboard() }
        showDashboard(hover: false)
    }

    // Opened by a click it takes the keyboard (Esc closes it). Opened by hovering over the notch it leaves
    // your typing alone and closes again when the mouse wanders off, unless you've clicked into it by then.
    func showDashboard(hover: Bool) {
        // clicking the bell or notch to close it first takes focus away, which already closed it a moment ago
        guard dashPanel == nil, welcome == nil, Date().timeIntervalSince(dashClosedAt) > 0.3 else { return }
        usageWaits = false
        if Date().timeIntervalSince(dashboard.usageAt) > 60 { refreshUsage() }
        dashboard.notch = notchSize
        dashboard.leaving = false
        let host = NSHostingView(rootView: DashboardView(
            model: dashboard,
            pick: { [weak self] id in self?.hideDashboard(); self?.pick(id) },
            pause: { [weak self] until in self?.dashboard.pausedUntil = until; self?.updateIcon() },
            editPatterns: { [weak self] in self?.hideDashboard(); self?.editPatterns() },
            showSettings: { [weak self] in self?.hideDashboard(); self?.showSettings() },
            openSettings: { [weak self] in self?.hideDashboard(); self?.openAutomationSettings() },
            connectClaude: { [weak self] in self?.connectClaude() },
            disconnectClaude: { [weak self] in self?.disconnectClaude() },
            welcome: { [weak self] in self?.hideDashboard(); self?.showWelcome() }))
        host.sizingOptions = [.intrinsicContentSize] // still reports its size, but leaves placing the window to us, pinned to the top of the screen
        let panel = NotchPanel(host, raised: 4) // above any card sitting in the notch
        panel.dismiss = { [weak self] in self?.hideDashboard() }
        dashByHover = hover
        awaySince = nil
        dashPanel = panel
        placeDashboard()
        if hover { panel.orderFrontRegardless() } else { panel.makeKeyAndOrderFront(nil) }
    }

    func hideDashboard() {
        guard let panel = dashPanel else { return }
        dashPanel = nil
        dashClosedAt = Date()
        dashboard.leaving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { panel.close() }
    }

    // usage loading in or a tab starting work changes its height, so this runs again after every dashboard update
    func placeDashboard() {
        dashPanel.map(hang)
    }

    // At its current size, hanging from the top middle of the notch screen
    func hang(_ panel: NSPanel) {
        guard let host = panel.contentView, let screen = notchScreen else { return }
        panel.setContentSize(host.fittingSize)
        panel.setFrameOrigin(NSPoint(x: screen.frame.midX - panel.frame.width / 2, y: screen.frame.maxY - panel.frame.height))
    }

    // First-run setup out of the notch, or again from ⋯ → Welcome to Notchy. While it's up, tabs aren't read
    // and usage isn't fetched, so the only macOS dialogs are the ones you click a button for.
    // Clicking elsewhere (or a macOS dialog taking focus) leaves it open, only Later, Esc or Finish close it.
    func showWelcome() {
        guard welcome == nil else { return }
        let model = Onboarding(claudeInstalled: ClaudeHooks.claudeInstalled, claudeConnected: ClaudeHooks.connected())
        model.notch = notchSize
        let host = NSHostingView(rootView: OnboardingView(
            model: model,
            connectClaude: { [weak self] in self?.connectClaude() },
            showUsage: { [weak self] in self?.refreshUsage() },
            openSettings: { [weak self] in self?.openAutomationSettings() },
            finish: { [weak self] in self?.finishWelcome(model) }))
        // One fixed window, tall enough for any step and pinned to the top, so moving between steps never
        // resizes it. A resize grows from the bottom edge and only gets pulled back up to the top a moment
        // later, which showed as a stutter and a gap under the notch. The black shape animates inside instead,
        // and the see-through rest of the window lets clicks pass.
        let width = host.fittingSize.width // measured first: once it stops sizing itself it reports 0×0
        host.sizingOptions = []
        let panel = NotchPanel(host, raised: 4)
        panel.setContentSize(NSSize(width: width, height: 460))
        welcome = panel
        if let screen = notchScreen {
            panel.setFrameOrigin(NSPoint(x: screen.frame.midX - panel.frame.width / 2, y: screen.frame.maxY - panel.frame.height))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func finishWelcome(_ model: Onboarding) {
        guard let panel = welcome else { return }
        UserDefaults.standard.set(true, forKey: "onboarded")
        welcome = nil
        model.leaving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { panel.close() }
        // never got to "Show my limits", so leave the Keychain alone until you open the dashboard
        if dashboard.usageAt == .distantPast { usageWaits = true }
    }

    // Resting the mouse on the notch for a tenth of a second opens the dashboard; just brushing past on the
    // way to the menu bar doesn't. If hovering opened it, it closes once the mouse has been off it for a
    // quarter of a second, unless you clicked into it by then (then Esc or clicking away closes it).
    //
    // ponytail: this looks at the mouse 20 times a second rather than using tracking areas. Those got stuck
    // after the dashboard covered the notch: they never saw the mouse leave, so never saw it come back.
    // A cheap position check can't get out of step like that.
    func checkHover() {
        let mouse = NSEvent.mouseLocation
        let now = Date()
        if let panel = dashPanel {
            guard dashByHover, !panel.isKeyWindow else { return }
            // a point of slack all round: with the cursor pushed up into the notch it sits on the very top
            // edge, which a plain contains() counts as outside, and the dashboard would flicker open and shut
            if panel.frame.insetBy(dx: -1, dy: -1).contains(mouse) { awaySince = nil; return }
            if now.timeIntervalSince(awaySince ?? now) > 0.25 { hideDashboard() } else if awaySince == nil { awaySince = now }
            return
        }
        // a card sitting in the notch already owns that spot
        guard order.isEmpty, welcome == nil, let rect = notchRect, rect.contains(mouse) else { hoverSince = nil; return }
        if now.timeIntervalSince(hoverSince ?? now) >= 0.1 { hoverSince = nil; showDashboard(hover: true) } else if hoverSince == nil { hoverSince = now }
    }

    // The notch on screen, a point taller so the very top row of pixels counts too
    var notchRect: NSRect? {
        let size = notchSize
        guard size.width > 0, let screen = notchScreen else { return nil }
        return NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height + 1)
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
    func isLooking(at id: String) -> Bool {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        return Terminals.hostIsFront(id) && fronts.contains(id) && idle < 60
    }

    @objc func hook(_ note: Notification) {
        guard let id = note.object as? String, let info = note.userInfo as? [String: String] else { return }
        if let place = info["place"] { places[id] = place; cards[id]?.place = place }
        if info["kind"] == "detail" {
            let d = Detail(title: info["title"] ?? "", body: info["body"] ?? "",
                           diff: (info["diff"] ?? "").split(separator: "\n").map(String.init))
            if let card = cards[id] { card.detail = d } else { details[id] = d }
            return
        }
        // Claude finished and is sitting at its input box
        guard cards[id] == nil, !dashboard.paused, let s = known[id], !isLooking(at: id) else { return }
        open(s, Prompt(kind: .idle, line: info["body"] ?? "Claude is waiting for your input", context: finishedSummary(screen: s.tail)), detail: nil)
        relayout()
    }

    // MARK: cards

    func open(_ s: Session, _ prompt: Prompt, detail: Detail?) {
        log("open \(s.id) \(prompt.kind) \(prompt.line.debugDescription) rows \(prompt.rows.map(\.label)) cursor \(prompt.cursor)")
        let card = CardModel(session: s.id, title: s.name, prompt: prompt, detail: detail)
        card.place = places[s.id] ?? ""
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
        Prefs.chime()
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { panel.close() } // once it has folded away
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
            close(id, "opened in its terminal")
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
        let tab = card.title, command = card.detail?.body ?? expected.context.joined(separator: " ")
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
        terminals.queue.async { [self] in
            var prompt = expected
            if !trustCard {
                // Re-read the screen first. If the prompt is gone, a late click must not type into whatever is there now.
                let tail = terminals.readTail(where_)
                let now = detectPrompt(screen: tail, patterns: pats, quietFor: .infinity)
                let still = expected.kind == .idle ? tail == snapshot : now.map { $0.kind == expected.kind && $0.line == expected.line } ?? false
                guard still else {
                    log("answer \(id) \(a) dropped, screen now shows \(String(describing: now))")
                    return DispatchQueue.main.async { self.inFlight[id, default: 1] -= 1; self.close(id, "prompt changed before the click landed") }
                }
                if expected.kind != .idle, let now { prompt = now } // fresh cursor, in case you moved it in the terminal
            }
            // Terminal types a whole line at a time, and an answer that can't be one comes back empty and fails
            let (keys, gap) = Terminals.app(of: id) == Terminals.terminal
                ? (terminalLine(for: a, in: prompt).map { [$0] } ?? [], 0) : keys(for: a, in: prompt)
            let ok = terminals.send(where_, keys, gap: gap)
            log("answer \(id) \(a) cursor \(prompt.cursor) keys \(keys) trusted card: \(trustCard) sent: \(ok)")

            // Watch just this tab (~30ms a look, vs ~500ms to read every tab) until Claude has redrawn:
            // the screen changed and looks the same on the next look. Then show it on the card right away.
            var fresh: (tail: String, prompt: Prompt?)?
            var last: Prompt?? = .none
            for _ in 0..<25 where ok {
                let tail = terminals.readTail(where_)
                let now = detectPrompt(screen: tail, patterns: pats, quietFor: .infinity)
                if now != prompt, case .some(let previous) = last, previous == now { fresh = (tail, now); break }
                last = .some(now)
                Thread.sleep(forTimeInterval: 0.06)
            }

            DispatchQueue.main.async {
                self.inFlight[id, default: 1] -= 1
                self.typedAt[id] = Date()
                if ok, let label = answerLabel(a, in: prompt) {
                    History.shared.add(HistoryEntry(at: Date(), tab: tab, question: expected.line, answer: label, command: command))
                }
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
        known[id].map(terminals.focus)
    }

    // one Settings window, brought forward again if it's already open
    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "Notchy Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func openAutomationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }

    func connectClaude() {
        do {
            try ClaudeHooks.connect()
            log("connected Claude Code hooks: \(ClaudeHooks.command)")
        } catch {
            log("couldn't connect Claude Code hooks: \(error)")
            NSSound.beep()
        }
        dashboard.claudeConnected = ClaudeHooks.connected()
    }

    func disconnectClaude() {
        do {
            try ClaudeHooks.disconnect()
            log("disconnected Claude Code hooks")
        } catch {
            log("couldn't disconnect Claude Code hooks: \(error)")
            NSSound.beep()
        }
        dashboard.claudeConnected = ClaudeHooks.connected() || !ClaudeHooks.claudeInstalled
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
