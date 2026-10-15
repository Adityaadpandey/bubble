import SwiftUI

// Everything Settings can change. Each one is a plain UserDefaults key, so the Settings window binds to it with
// @AppStorage and the rest of the app just reads it when it needs it, e.g. Prefs.int("nudgeSeconds") is 120.
// Cards and the dashboard are built fresh each time they open, so a change shows on the next one.
enum Prefs {
    static let defaults: [String: Any] = [
        "nudgeSeconds": 120,     // how long a prompt waits before the second ping, 0 = never
        "sound": "Glass",        // a macOS system sound by name, "" = silent
        "quiet.on": false, "quiet.from": 22, "quiet.to": 8, // no chime between these hours
        "shortcut": "ctrlOptSpace",
        "watch.iterm": true, "watch.terminal": true, "watch.tmux": true, "watch.kitty": true, "watch.wezterm": true,
        "meter.Claude": true, "meter.Codex": true, "meter.Command Code": true,
        "spacing": "comfortable", "accent": "system", "width": "normal", "textSize": "normal",
    ]

    static func register() { UserDefaults.standard.register(defaults: defaults) }
    static func bool(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }
    static func int(_ key: String) -> Int { UserDefaults.standard.integer(forKey: key) }
    static func string(_ key: String) -> String { UserDefaults.standard.string(forKey: key) ?? "" }

    // the chime when a card opens and for the second ping, unless you picked silence
    static func chime() {
        let name = string("sound")
        let hour = Calendar.current.component(.hour, from: Date())
        if bool("quiet.on"), isQuiet(hour: hour, from: int("quiet.from"), to: int("quiet.to")) { return }
        if !name.isEmpty { NSSound(named: name)?.play() }
    }

    // the pieces of Settings that need something redone when they change (the hotkey, the usage meters)
    static var watchedChoices: String { ["shortcut", "meter.Claude", "meter.Codex", "meter.Command Code"].map { "\($0)=\(string($0))\(bool($0))" }.joined() }
}

/// Is `hour` inside quiet hours, which may run past midnight? 22 to 8 covers 23, 0 and 7 but not 8 or 12, and 9 to 17 is a work day.
func isQuiet(hour: Int, from: Int, to: Int) -> Bool {
    if from == to { return false }
    return from < to ? (from..<to).contains(hour) : hour >= from || hour < to
}

// How cards and the dashboard look. The "comfortable", "normal" names are what the Settings pickers store.
enum Look {
    // space inside a card: 10 compact, 14 as it always was, 18 roomy
    static var padding: CGFloat { padding(Prefs.string("spacing")) }
    static func padding(_ name: String) -> CGFloat { ["compact": 10, "roomy": 18][name] ?? 14 }

    // text: small 0.9, normal 1, large 1.15 times the size written in the code
    static var textScale: CGFloat { textScale(Prefs.string("textSize")) }
    static func textScale(_ name: String) -> CGFloat { ["small": 0.9, "large": 1.15][name] ?? 1 }

    // the card's width, which still follows its content inside this range
    static var width: ClosedRange<CGFloat> { width(Prefs.string("width")) }
    static func width(_ name: String) -> ClosedRange<CGFloat> {
        switch name {
        case "narrow": 420...560
        case "wide": 600...860
        default: 510...720
        }
    }

    static let accents: [(id: String, label: String, color: Color)] = [
        ("system", "System", .accentColor), ("orange", "Orange", .orange), ("blue", "Blue", .blue),
        ("green", "Green", .green), ("purple", "Purple", .purple), ("pink", "Pink", .pink),
    ]
    static var accent: Color { accents.first { $0.id == Prefs.string("accent") }?.color ?? .accentColor }
}

extension Font {
    /// `.system(size:)` that follows the text size setting, e.g. .notchy(12) is 13.8pt on large.
    static func notchy(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: size * Look.textScale, weight: weight, design: design)
    }
}
