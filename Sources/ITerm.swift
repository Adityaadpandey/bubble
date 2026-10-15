import AppKit
import Carbon

// Where a tab lives, so the next call can jump straight to it instead of searching every window
struct Session {
    let id, name, tail: String
    let window, tab, pane: Int
}

// Everything we ask iTerm2 goes through here, on one background queue, so a slow Apple Event never
// freezes the cards (reading every tab takes ~0.5s). The script is compiled once and its handlers are
// called with real arguments, so keys and reply text travel as data and are never pasted into script source.
final class ITerm {
    static let bundleID = "com.googlecode.iterm2"
    let queue = DispatchQueue(label: "notiapp.iterm")
    var onDenied: (Bool) -> Void = { _ in }
    private let script: NSAppleScript

    // Compile here, on the main thread. A script compiled on a background thread hangs forever
    // the first time it runs there, while one compiled on main runs fine from any queue.
    init() {
        script = NSAppleScript(source: Self.source)!
        var err: NSDictionary?
        script.compileAndReturnError(&err)
    }

    private static let source = """
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
                            set end of out to {unique id of s, name of s, my tailof(s), id of w, ti, si}
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

    // MARK: called from the main thread, answers come back on the main thread

    func readAll(_ done: @escaping ((front: String, sessions: [Session])?) -> Void) {
        queue.async {
            let r = self.call("readall", [])
            let result = r.flatMap { r -> (String, [Session])? in
                guard let list = r.atIndex(2) else { return nil }
                let sessions = (0..<list.numberOfItems).compactMap { i -> Session? in
                    guard let item = list.atIndex(i + 1), let id = item.atIndex(1)?.stringValue else { return nil }
                    return Session(id: id, name: item.atIndex(2)?.stringValue ?? "iTerm2", tail: item.atIndex(3)?.stringValue ?? "",
                                   window: Int(item.atIndex(4)?.int32Value ?? 0), tab: Int(item.atIndex(5)?.int32Value ?? 0),
                                   pane: Int(item.atIndex(6)?.int32Value ?? 0))
                }
                return (r.atIndex(1)?.stringValue ?? "", sessions)
            }
            DispatchQueue.main.async { done(result) }
        }
    }

    func focus(_ s: Session) {
        queue.async { _ = self.call("focus", [s.id]) }
    }

    // MARK: only call these on `queue`

    func readTail(_ s: Session) -> String {
        call("readone", [s.id, s.window, s.tab, s.pane])?.stringValue ?? ""
    }

    // true only if every key made it into the tab
    func send(_ s: Session, _ keys: [String], gap: Double) -> Bool {
        call("sendkeys", [s.id, s.window, s.tab, s.pane, keys, gap])?.booleanValue ?? false
    }

    private func call(_ handler: String, _ args: [Any]) -> NSAppleEventDescriptor? {
        // talking to iTerm2 would launch it, so only do it when it's already up
        guard NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first != nil else { return nil }
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite), eventID: AEEventID(kASSubroutineEvent),
                                           targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setDescriptor(NSAppleEventDescriptor(string: handler), forKeyword: AEKeyword(keyASSubroutineName))
        event.setDescriptor(Self.descriptor(args), forKeyword: keyDirectObject)

        var err: NSDictionary?
        let result = script.executeAppleEvent(event, error: &err)
        // -1743: you said no (or haven't been asked yet) to letting NotiApp control iTerm2
        let denied = (err?[NSAppleScript.errorNumber] as? Int) == -1743
        DispatchQueue.main.async { self.onDenied(denied) }
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
