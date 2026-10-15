import AppKit
import Carbon

// Everything we ask iTerm2 and Terminal goes through here, on one background queue, so a slow Apple Event
// never freezes the cards (reading every tab takes ~0.5s). Each app gets its own script with the same
// handlers (readall, readone, sendkeys, focus). The scripts are compiled once and called with real
// arguments, so keys and reply text travel as data and are never pasted into script source.
final class Terminals {
    static let iTerm = "com.googlecode.iterm2", terminal = "com.apple.Terminal"
    static func app(of id: String) -> String { id.hasPrefix("/dev/") ? terminal : iTerm }

    static let backends: [PaneBackend] = [TmuxBackend(), KittyBackend()]
    static func backend(for id: String) -> PaneBackend? { backends.first { id.hasPrefix($0.prefix) } }

    // is the terminal showing this tab the app in front? A tmux pane could be in any terminal, so any known one will do.
    static func hostIsFront(_ id: String) -> Bool {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        guard let b = backend(for: id) else { return front == app(of: id) }
        return b.bundle.map { $0 == front } ?? terminalApps.contains(front)
    }

    let queue = DispatchQueue(label: "notchy.terminals")
    var onDenied: (Bool) -> Void = { _ in }
    private var denied: [String: Bool] = [:] // per app, only touched on `queue`
    private let scripts: [String: NSAppleScript]

    // Compile here, on the main thread. A script compiled on a background thread hangs forever
    // the first time it runs there, while one compiled on main runs fine from any queue.
    init() {
        scripts = [Self.iTerm: Self.iTermSource, Self.terminal: Self.terminalSource].mapValues { source in
            let script = NSAppleScript(source: source)!
            var err: NSDictionary?
            script.compileAndReturnError(&err)
            return script
        }
    }

    private static let iTermSource = """
        on tailof(s)
            tell application "iTerm2" to set c to contents of s
            set n to count of paragraphs of c
            if n > 50 then set n to 50
            if n = 0 then return ""
            set AppleScript's text item delimiters to linefeed
            return (paragraphs -n thru -1 of c) as text
        end tailof

        on readall()
            set out to {}
            set frontID to ""
            tell application "iTerm2"
                try
                    set frontID to unique id of current session of current tab of current window
                end try
                repeat with w in windows
                    set ti to 0
                    repeat with t in tabs of w
                        set ti to ti + 1
                        set si to 0
                        repeat with s in sessions of t
                            set si to si + 1
                            set end of out to {unique id of s, name of s, my tailof(s), id of w, ti, si, tty of s}
                        end repeat
                    end repeat
                end repeat
            end tell
            return {frontID, out}
        end readall

        -- straight to window/tab/pane from the last read, and only search everything if the tab moved
        on findsession(sid, wid, ti, si)
            tell application "iTerm2"
                try
                    set s to session si of tab ti of window id wid
                    if unique id of s is sid then return s
                end try
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if unique id of s is sid then return s
                        end repeat
                    end repeat
                end repeat
            end tell
            return missing value
        end findsession

        on readone(sid, wid, ti, si)
            set s to findsession(sid, wid, ti, si)
            if s is missing value then return ""
            return tailof(s)
        end readone

        -- keys are read by index: inside a tell to iTerm2, "contents of k" means iTerm2's own
        -- contents property and fails, which used to silently drop every key
        on sendkeys(sid, wid, ti, si, keyList, gap)
            set s to findsession(sid, wid, ti, si)
            if s is missing value then return false
            repeat with i from 1 to count of keyList
                set k to item i of keyList
                tell application "iTerm2" to tell s to write text k newline NO
                delay gap
            end repeat
            return true
        end sendkeys

        on focus(sid)
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if unique id of s is sid then
                                tell w to select
                                tell t to select
                                tell s to select
                                activate
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
        end focus
        """

    // Terminal has no panes, and tabs are always spelled out as "tab 2 of window id 4711": "contents of t"
    // with t holding a tab gets swallowed by AppleScript's own "contents of" and hands back the tab itself.
    private static let terminalSource = """
        on tailof(wid, ti)
            tell application "Terminal" to set c to contents of tab ti of window id wid
            set n to count of paragraphs of c
            if n > 50 then set n to 50
            if n = 0 then return ""
            set AppleScript's text item delimiters to linefeed
            return (paragraphs -n thru -1 of c) as text
        end tailof

        on readall()
            set out to {}
            set frontID to ""
            tell application "Terminal"
                try
                    set frontID to tty of selected tab of window 1
                end try
                repeat with w in windows
                    set wid to id of w
                    try
                        repeat with ti from 1 to count of tabs of w
                            set t to tab ti of window id wid
                            set nm to custom title of t
                            if processes of t contains "claude" then set nm to "Claude Code"
                            set end of out to {tty of t, nm, my tailof(wid, ti), wid, ti, 1}
                        end repeat
                    end try
                end repeat
            end tell
            return {frontID, out}
        end readall

        -- {window id, tab number} for a tty, straight from the last read unless the tab moved
        on findtab(tid, wid, ti)
            tell application "Terminal"
                try
                    if tty of tab ti of window id wid is tid then return {wid, ti}
                end try
                repeat with w in windows
                    set wid to id of w
                    try
                        repeat with ti from 1 to count of tabs of w
                            if tty of tab ti of window id wid is tid then return {wid, ti}
                        end repeat
                    end try
                end repeat
            end tell
            return missing value
        end findtab

        on readone(tid, wid, ti, si)
            set f to findtab(tid, wid, ti)
            if f is missing value then return ""
            return tailof(item 1 of f, item 2 of f)
        end readone

        -- do script types the line and presses Enter, so each item is a whole line (see terminalLine)
        on sendkeys(tid, wid, ti, si, keyList, gap)
            set f to findtab(tid, wid, ti)
            if f is missing value then return false
            repeat with i from 1 to count of keyList
                set k to item i of keyList
                tell application "Terminal" to do script k in tab (item 2 of f) of window id (item 1 of f)
                delay gap
            end repeat
            return true
        end sendkeys

        on focus(tid)
            set f to findtab(tid, 0, 0)
            if f is missing value then return
            tell application "Terminal"
                set selected of tab (item 2 of f) of window id (item 1 of f) to true
                set index of window id (item 1 of f) to 1
                activate
            end tell
        end focus
        """

    // MARK: called from the main thread, answers come back on the main thread

    // `fronts` has the tab in front in each app, e.g. one iTerm2 session id and one tty
    func readAll(_ done: @escaping ((fronts: [String], sessions: [Session])?) -> Void) {
        queue.async {
            var fronts: [String] = [], sessions: [Session] = [], failed = false
            for app in [Self.iTerm, Self.terminal] {
                // talking to an app would launch it, so only do it when it's already up
                guard NSRunningApplication.runningApplications(withBundleIdentifier: app).first != nil else {
                    self.denied[app] = nil
                    continue
                }
                guard let r = self.call(app, "readall", []), let list = r.atIndex(2) else {
                    // a read that just failed would look like every tab there had closed, so skip this round.
                    // An app you said no to is simply left out, the other one still works.
                    if self.denied[app] != true { failed = true }
                    continue
                }
                fronts.append(r.atIndex(1)?.stringValue ?? "")
                sessions += (0..<list.numberOfItems).compactMap { i -> Session? in
                    guard let item = list.atIndex(i + 1), let id = item.atIndex(1)?.stringValue else { return nil }
                    return Session(id: id, name: item.atIndex(2)?.stringValue ?? (app == Self.iTerm ? "iTerm2" : "Terminal"),
                                   tail: item.atIndex(3)?.stringValue ?? "",
                                   window: Int(item.atIndex(4)?.int32Value ?? 0), tab: Int(item.atIndex(5)?.int32Value ?? 0),
                                   pane: Int(item.atIndex(6)?.int32Value ?? 0),
                                   tty: app == Self.terminal ? id : item.atIndex(7)?.stringValue ?? "")
                }
            }
            // a tab that's only showing a tmux session is left out, its panes are listed on their own
            var attached = Set<String>()
            for b in Self.backends {
                if let bundle = b.bundle, !isRunning(bundle) { continue }
                guard let r = b.list() else { continue } // ponytail: a failed read drops that backend's cards for one tick, add a failed flag if it flickers
                fronts += r.fronts
                sessions += r.sessions
                attached.formUnion(b.clientTTYs())
            }
            sessions.removeAll { attached.contains($0.tty) }
            let anyDenied = self.denied.values.contains(true)
            DispatchQueue.main.async {
                self.onDenied(anyDenied)
                done(failed ? nil : (fronts, sessions))
            }
        }
    }

    func focus(_ s: Session) {
        queue.async {
            if let b = Self.backend(for: s.id) { return b.focus(s.id) }
            _ = self.call(Self.app(of: s.id), "focus", [s.id])
        }
    }

    // MARK: only call these on `queue`

    func readTail(_ s: Session) -> String {
        if let b = Self.backend(for: s.id) { return b.read(s.id) }
        return call(Self.app(of: s.id), "readone", [s.id, s.window, s.tab, s.pane])?.stringValue ?? ""
    }

    // true only if every key made it into the tab
    func send(_ s: Session, _ keys: [String], gap: Double) -> Bool {
        guard !keys.isEmpty else { return false }
        if let b = Self.backend(for: s.id) { return b.send(s.id, keys, gap: gap) }
        return call(Self.app(of: s.id), "sendkeys", [s.id, s.window, s.tab, s.pane, keys, gap])?.booleanValue ?? false
    }

    private func call(_ app: String, _ handler: String, _ args: [Any]) -> NSAppleEventDescriptor? {
        guard let script = scripts[app], NSRunningApplication.runningApplications(withBundleIdentifier: app).first != nil else { return nil }
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite), eventID: AEEventID(kASSubroutineEvent),
                                           targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setDescriptor(NSAppleEventDescriptor(string: handler), forKeyword: AEKeyword(keyASSubroutineName))
        event.setDescriptor(Self.descriptor(args), forKeyword: keyDirectObject)

        var err: NSDictionary?
        let result = script.executeAppleEvent(event, error: &err)
        // -1743: you said no (or haven't been asked yet) to letting Notchy control this app
        denied[app] = (err?[NSAppleScript.errorNumber] as? Int) == -1743
        return err == nil ? result : nil
    }

    private static func descriptor(_ value: Any) -> NSAppleEventDescriptor {
        switch value {
        case let s as String: return NSAppleEventDescriptor(string: s)
        case let i as Int: return NSAppleEventDescriptor(int32: Int32(i))
        case let d as Double: return NSAppleEventDescriptor(double: d)
        case let list as [Any]:
            let l = NSAppleEventDescriptor.list()
            for (i, v) in list.enumerated() { l.insert(descriptor(v), at: i + 1) }
            return l
        default: return NSAppleEventDescriptor.null()
        }
    }
}
