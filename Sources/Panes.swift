import Foundation

// Where a tab lives, so the next call can jump straight to it instead of searching every window.
// iTerm2 tabs go by iTerm2's session id, Terminal tabs by their tty, e.g. "/dev/ttys019".
// Panes in tmux, kitty and WezTerm go by "tmux:%5", "kitty:/tmp/kitty-123#7" and "wezterm:4".
struct Session {
    let id, name, tail: String
    let window, tab, pane: Int
    var tty = "" // the tty this tab is attached to, so a tmux client sitting in it can be spotted
}

// One pane as a tmux, kitty or WezTerm listing describes it, before its screen has been read
struct Pane: Equatable {
    let id: String
    let name: String
    var focused = false
}

// The name a tab gets on the dashboard. Anything running claude is "Claude Code", the way Terminal's tabs are named.
func paneName(_ title: String, running: [String]) -> String {
    running.contains { $0.localizedCaseInsensitiveContains("claude") } ? "Claude Code" : title
}

// `tmux list-panes -a -F '#{pane_id} #{session_name} #{window_name} #{pane_current_command} #{window_active}
// #{pane_active} #{session_attached}'`, separated by tabs, e.g. "%5\twork\tapi\tclaude\t1\t1\t1".
// A pane counts as in front when it's the active pane of the active window in a session someone is attached to.
func parseTmuxPanes(_ out: String) -> [Pane] {
    out.split(separator: "\n").compactMap { line in
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 7 else { return nil }
        return Pane(id: f[0], name: paneName("tmux \(f[1]):\(f[2])", running: [f[3]]),
                    focused: f[4] == "1" && f[5] == "1" && f[6] != "0")
    }
}

// `kitten @ ls`: OS windows holding tabs holding windows, which are the panes we read, e.g.
//   [{"tabs": [{"windows": [{"id": 7, "title": "claude", "is_focused": true, "foreground_processes": [{"cmdline": ["claude"]}]}]}]}]
// `focused` needs the window and its OS window to be the one in front, and is_focused is only true for that one.
func parseKittyWindows(_ json: Data) -> [Pane] {
    guard let osWindows = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]] else { return [] }
    return osWindows.flatMap { os in
        (os["tabs"] as? [[String: Any]] ?? []).flatMap { tab in
            (tab["windows"] as? [[String: Any]] ?? []).compactMap { w -> Pane? in
                guard let id = w["id"] as? Int else { return nil }
                let running = (w["foreground_processes"] as? [[String: Any]] ?? []).flatMap { $0["cmdline"] as? [String] ?? [] }
                return Pane(id: String(id), name: paneName(w["title"] as? String ?? "kitty", running: running),
                            focused: (os["is_focused"] as? Bool ?? false) && (tab["is_focused"] as? Bool ?? false)
                                && (w["is_focused"] as? Bool ?? false))
            }
        }
    }
}

// `wezterm cli list --format json`, e.g. [{"pane_id": 4, "title": "claude", "tab_id": 1, "window_id": 0}].
// The pane that has the keyboard comes from `wezterm cli list-clients --format json`, [{"focused_pane_id": 4}].
func parseWezTermPanes(_ list: Data, clients: Data?) -> [Pane] {
    let focused = clients.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }?
        .compactMap { $0["focused_pane_id"] as? Int } ?? []
    let panes = (try? JSONSerialization.jsonObject(with: list) as? [[String: Any]]) ?? []
    return panes.compactMap { p in
        guard let id = p["pane_id"] as? Int else { return nil }
        return Pane(id: String(id), name: paneName(p["title"] as? String ?? "WezTerm", running: [p["title"] as? String ?? ""]),
                    focused: focused.contains(id))
    }
}

// The last 50 lines of a screen without the empty rows under the cursor, the same tail iTerm2 and Terminal give us
func screenTail(_ screen: String) -> String {
    var lines = screen.components(separatedBy: "\n")
    while let l = lines.last, l.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
    return lines.suffix(50).joined(separator: "\n")
}
