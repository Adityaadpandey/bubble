import SwiftUI

// The Settings window, opened from the ⋯ menu. Every control is bound to the UserDefaults key Prefs.swift reads,
// so there's no Save button: change something and it's already in effect (cards you open next look the new way).
struct SettingsView: View {
    @AppStorage("nudgeSeconds") private var nudge = 120
    @AppStorage("sound") private var sound = "Glass"
    @AppStorage("shortcut") private var shortcut = "ctrlOptSpace"
    @AppStorage("quiet.on") private var quietOn = false
    @AppStorage("quiet.from") private var quietFrom = 22
    @AppStorage("quiet.to") private var quietTo = 8
    @AppStorage("spacing") private var spacing = "comfortable"
    @AppStorage("accent") private var accent = "system"
    @AppStorage("width") private var width = "normal"
    @AppStorage("textSize") private var textSize = "normal"

    private let sounds = ["Glass", "Ping", "Pop", "Tink", "Hero", "Funk", "Submarine", "Sosumi"]
    private let terminals = [("iterm", "iTerm2"), ("terminal", "Terminal"), ("tmux", "tmux"), ("kitty", "kitty"), ("wezterm", "WezTerm")]
    private let meters = ["Claude", "Codex", "Command Code"]

    var body: some View {
        TabView {
            form.tabItem { Label("Settings", systemImage: "gearshape") }
            HistoryView().tabItem { Label("History", systemImage: "clock") }
        }
        .frame(width: 440, height: 600)
    }

    private var form: some View {
        Form {
            Section("Alerts") {
                Picker("Remind me again after", selection: $nudge) {
                    Text("Never").tag(0)
                    Text("1 minute").tag(60)
                    Text("2 minutes").tag(120)
                    Text("5 minutes").tag(300)
                }
                Picker("Sound", selection: $sound) {
                    Text("None").tag("")
                    ForEach(sounds, id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: sound) { _, name in NSSound(named: name)?.play() }
                Picker("Keyboard shortcut", selection: $shortcut) {
                    ForEach(Shortcut.choices, id: \.id) { Text($0.label).tag($0.id) }
                    Text("Off").tag("off")
                }
            }

            Section {
                Toggle("Mute the sound at night", isOn: $quietOn)
                if quietOn {
                    Picker("From", selection: $quietFrom) { ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) } }
                    Picker("Until", selection: $quietTo) { ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) } }
                }
            } header: {
                Text("Quiet hours")
            } footer: {
                Text("Cards still appear, they just arrive without the sound.")
            }

            Section {
                ForEach(terminals, id: \.0) { key, name in
                    DefaultsToggle(name, key: "watch." + key)
                }
            } header: {
                Text("Watch these terminals")
            } footer: {
                Text("One you turn off is never read, and macOS won't ask to let Notchy control it.")
            }

            Section("Show usage for") {
                ForEach(meters, id: \.self) { DefaultsToggle($0, key: "meter." + $0) }
            }

            Section("Look") {
                Picker("Spacing", selection: $spacing) {
                    Text("Compact").tag("compact")
                    Text("Comfortable").tag("comfortable")
                    Text("Roomy").tag("roomy")
                }
                Picker("Card width", selection: $width) {
                    Text("Narrow").tag("narrow")
                    Text("Normal").tag("normal")
                    Text("Wide").tag("wide")
                }
                Picker("Text size", selection: $textSize) {
                    Text("Small").tag("small")
                    Text("Normal").tag("normal")
                    Text("Large").tag("large")
                }
                LabeledContent("Accent") {
                    HStack(spacing: 10) {
                        ForEach(Look.accents, id: \.id) { a in
                            Button { accent = a.id } label: {
                                Circle().fill(a.color).frame(width: 18, height: 18)
                                    .overlay(Circle().strokeBorder(.primary, lineWidth: accent == a.id ? 2 : 0).padding(-3))
                            }
                            .buttonStyle(.plain).help(a.label)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// What you answered from the notch, newest first, e.g. "Claude Code · notchy   Yes   rm -rf build"
private struct HistoryView: View {
    @ObservedObject private var history = History.shared

    var body: some View {
        VStack(spacing: 0) {
            if history.entries.isEmpty {
                Text("Nothing yet. Answers you send from the notch show up here.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(history.entries) { e in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(e.tab).fontWeight(.medium).lineLimit(1)
                            Spacer()
                            Text(e.at.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                        }
                        Text(e.question).foregroundStyle(.secondary).lineLimit(2)
                        if !e.command.isEmpty {
                            Text(e.command).font(.system(size: 11, design: .monospaced)).lineLimit(2).textSelection(.enabled)
                        }
                        Text(e.answer).font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(e.answer.hasPrefix("No") ? Color.red : .green)
                    }
                    .font(.system(size: 12))
                    .padding(.vertical, 3)
                }
            }
            Divider()
            HStack {
                Text("Typed replies are never saved.").font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                Button("Clear", role: .destructive) { history.clear() }.disabled(history.entries.isEmpty)
            }
            .padding(10)
        }
    }
}

// A switch for a UserDefaults key chosen at run time, e.g. "watch.tmux" (a plain @AppStorage needs its key written out up front)
private struct DefaultsToggle: View {
    let title: String
    @AppStorage private var isOn: Bool

    init(_ title: String, key: String) {
        self.title = title
        _isOn = AppStorage(wrappedValue: true, key)
    }

    var body: some View { Toggle(title, isOn: $isOn) }
}
