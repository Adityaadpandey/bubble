import AppKit

// tmux, kitty and WezTerm can't be scripted with AppleScript, but each has a command that lists its panes, prints
// one's screen and types into it. Panes from here come back as ordinary Sessions, so cards, answers and the
// dashboard treat them like iTerm2 and Terminal tabs.
protocol PaneBackend {
    var prefix: String { get }  // starts every id from this backend, e.g. "tmux:" for "tmux:%5"
    var bundle: String? { get } // the app to bring forward, nil when we can't tell which terminal is hosting
    func list() -> (fronts: [String], sessions: [Session])?
    func read(_ id: String) -> String
    func send(_ id: String, _ keys: [String], gap: Double) -> Bool
    func focus(_ id: String)
    func clientTTYs() -> [String]
}

extension PaneBackend {
    func clientTTYs() -> [String] { [] }
    func name(of id: String) -> String { String(id.dropFirst(prefix.count)) }
}

// Terminals we know of, so a tmux pane counts as looked at when any of them is in front
let terminalApps: Set<String> = [
    "com.googlecode.iterm2", "com.apple.Terminal", "net.kovidgoyal.kitty", "com.github.wez.wezterm", "com.mitchellh.ghostty",
    "dev.warp.Warp-Stable", "org.alacritty", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
]

func firstExisting(_ paths: [String]) -> String? { paths.first { FileManager.default.isExecutableFile(atPath: $0) } }

func isRunning(_ bundle: String) -> Bool { NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first != nil }

/// Runs a command and returns what it printed, or nil if it failed or took over 3 seconds,
/// e.g. run("/opt/homebrew/bin/tmux", ["capture-pane", "-p", "-t", "%5"]). `input` goes to its stdin.
func run(_ exe: String, _ args: [String], input: String? = nil) -> Data? {
    let p = Process(), out = Pipe(), inp = Pipe()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    p.standardInput = inp
    do { try p.run() } catch { return nil }
    // a dead socket or a wedged terminal must not freeze the read loop
    let kill = DispatchWorkItem { p.terminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: kill)
    if let input { inp.fileHandleForWriting.write(Data(input.utf8)) }
    try? inp.fileHandleForWriting.close()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    kill.cancel()
    return p.terminationStatus == 0 ? data : nil
}

private func text(_ data: Data?) -> String { data.flatMap { String(data: $0, encoding: .utf8) } ?? "" }

// Panes of every tmux session, in whatever terminal they're shown in. A pane's keys go through
// `send-keys -l`, so "\u{1b}[B" arrives as the three bytes an arrow key sends and "\r" as Enter.
struct TmuxBackend: PaneBackend {
    let prefix = "tmux:"
    let bundle: String? = nil
    private let exe = firstExisting(["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"])

    func list() -> (fronts: [String], sessions: [Session])? {
        guard let exe, let out = run(exe, ["list-panes", "-a", "-F",
              "#{pane_id}\t#{session_name}\t#{window_name}\t#{pane_current_command}\t#{window_active}\t#{pane_active}\t#{session_attached}"])
        else { return nil } // no tmux server running
        let panes = parseTmuxPanes(text(out))
        return (panes.filter(\.focused).map { prefix + $0.id },
                panes.map { Session(id: prefix + $0.id, name: $0.name, tail: read(prefix + $0.id), window: 0, tab: 0, pane: 0) })
    }

    func read(_ id: String) -> String {
        guard let exe else { return "" }
        return screenTail(text(run(exe, ["capture-pane", "-p", "-t", name(of: id)])))
    }

    func send(_ id: String, _ keys: [String], gap: Double) -> Bool {
        guard let exe else { return false }
        for (i, key) in keys.enumerated() where !key.isEmpty {
            if i > 0 { Thread.sleep(forTimeInterval: gap) }
            guard run(exe, ["send-keys", "-t", name(of: id), "-l", "--", key]) != nil else { return false }
        }
        return true
    }

    func focus(_ id: String) {
        guard let exe else { return }
        _ = run(exe, ["select-window", "-t", name(of: id)])
        _ = run(exe, ["select-pane", "-t", name(of: id)])
        // tmux can't say which window shows it, so bring whichever terminal is running forward
        NSWorkspace.shared.runningApplications.first { terminalApps.contains($0.bundleIdentifier ?? "") }?.activate()
    }

    // the ttys tmux is attached from, e.g. "/dev/ttys003", so the iTerm2 or Terminal tab showing a tmux session isn't listed twice
    func clientTTYs() -> [String] {
        guard let exe else { return [] }
        return text(run(exe, ["list-clients", "-F", "#{client_tty}"])).split(separator: "\n").map(String.init)
    }
}

// kitty's remote control, which needs this in kitty.conf (the number kitty adds to the socket name is its pid):
//   allow_remote_control socket-only
//   listen_on unix:/tmp/kitty
// Ids look like "kitty:/tmp/kitty-4711#7", the socket and then kitty's window id. Text goes in on stdin,
// where kitty sends it as is, so an escape key needs no escaping.
struct KittyBackend: PaneBackend {
    let prefix = "kitty:"
    let bundle: String? = "net.kovidgoyal.kitty"
    private let exe = firstExisting(["/Applications/kitty.app/Contents/MacOS/kitten", "/opt/homebrew/bin/kitten", "/usr/local/bin/kitten"])

    // every kitty that's listening, e.g. ["/tmp/kitty-4711"]
    private var sockets: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/tmp")) ?? []
        return names.filter { $0.hasPrefix("kitty") }.map { "/tmp/" + $0 }.filter {
            (try? FileManager.default.attributesOfItem(atPath: $0)[.type] as? FileAttributeType) == .typeSocket
        }
    }

    private func call(_ socket: String, _ args: [String], input: String? = nil) -> Data? {
        exe.flatMap { run($0, ["@", "--to", "unix:" + socket] + args, input: input) }
    }

    // "/tmp/kitty-4711#7" is ("/tmp/kitty-4711", "7")
    private func split(_ id: String) -> (socket: String, window: String) {
        let rest = name(of: id)
        guard let hash = rest.lastIndex(of: "#") else { return (rest, "") }
        return (String(rest[..<hash]), String(rest[rest.index(after: hash)...]))
    }

    func list() -> (fronts: [String], sessions: [Session])? {
        var fronts: [String] = [], sessions: [Session] = []
        for socket in sockets {
            guard let ls = call(socket, ["ls"]) else { continue } // a socket left behind by a kitty that's gone
            for pane in parseKittyWindows(ls) {
                let id = "\(prefix)\(socket)#\(pane.id)"
                if pane.focused { fronts.append(id) }
                sessions.append(Session(id: id, name: pane.name, tail: read(id), window: 0, tab: 0, pane: 0))
            }
        }
        return (fronts, sessions)
    }

    func read(_ id: String) -> String {
        let (socket, window) = split(id)
        return screenTail(text(call(socket, ["get-text", "--match", "id:" + window])))
    }

    func send(_ id: String, _ keys: [String], gap: Double) -> Bool {
        let (socket, window) = split(id)
        for (i, key) in keys.enumerated() where !key.isEmpty {
            if i > 0 { Thread.sleep(forTimeInterval: gap) }
            guard call(socket, ["send-text", "--match", "id:" + window, "--stdin"], input: key) != nil else { return false }
        }
        return true
    }

    func focus(_ id: String) {
        let (socket, window) = split(id)
        _ = call(socket, ["focus-window", "--match", "id:" + window])
        NSRunningApplication.runningApplications(withBundleIdentifier: "net.kovidgoyal.kitty").first?.activate()
    }
}
