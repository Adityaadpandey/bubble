import Foundation

// Notchy spots prompts by reading the screen, but two Claude Code hooks make it better: the diff or command
// on permission cards, and a ping when Claude finishes and is waiting on you. Both run `Notchy hook`, and
// this adds them to ~/.claude/settings.json next to whatever hooks you already have, e.g.
//
//   "PermissionRequest": [
//     { "hooks": [{ "type": "command", "command": "/your/other/hook" }] },
//     { "hooks": [{ "type": "command", "command": "/Applications/Notchy.app/Contents/MacOS/Notchy hook" }] }
//   ]
//
// Other tools' hooks are left alone. An older Notchy entry (or one from when it was called Perch or NotiApp) is
// swapped for the current path, so moving the app never leaves Claude calling a file that isn't there.
enum ClaudeHooks {
    static let events = ["PermissionRequest", "Notification"]
    static let settings = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")

    static var command: String {
        let path = Bundle.main.executablePath ?? ""
        return (path.contains(" ") ? "\"\(path)\"" : path) + " hook"
    }

    // Claude Code is on this Mac at all, otherwise there's nothing to connect
    static var claudeInstalled: Bool {
        FileManager.default.fileExists(atPath: settings.deletingLastPathComponent().path)
    }

    static func connected(_ file: URL = settings) -> Bool { events.allSatisfy { commands(for: $0, in: file).contains(command) } }

    // some Notchy hook is there, maybe pointing at an old copy of the app
    static var added: Bool { events.contains { commands(for: $0, in: settings).contains(where: isNotchy) } }

    static func connect(_ settings: URL = settings) throws {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: settings) {
            // a settings file we can't read is left exactly as it is, never overwritten
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
            root = obj
            // one copy of how it was before Notchy first touched it
            let backup = settings.appendingPathExtension("before-notchy")
            if !FileManager.default.fileExists(atPath: backup.path) { try? data.write(to: backup) }
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var groups = (hooks[event] as? [[String: Any]] ?? []).compactMap { group -> [String: Any]? in
                let all = group["hooks"] as? [[String: Any]] ?? []
                let kept = all.filter { !isNotchy($0["command"] as? String ?? "") }
                if kept.isEmpty && !all.isEmpty { return nil } // that group was only ever Notchy
                var group = group
                group["hooks"] = kept
                return group
            }
            groups.append(["hooks": [["type": "command", "command": command]]])
            hooks[event] = groups
        }
        root["hooks"] = hooks
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: settings, options: .atomic)
    }

    private static func isNotchy(_ command: String) -> Bool {
        command == Self.command || command.hasSuffix(" hook") && ["/Notchy", "/Perch", "/NotiApp"].contains(where: command.contains)
    }

    private static func commands(for event: String, in file: URL) -> [String] {
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = (root["hooks"] as? [String: Any])?[event] as? [[String: Any]] else { return [] }
        return groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }
}
