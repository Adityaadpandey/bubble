import ServiceManagement
import SwiftUI

enum TabState { case waiting, working, idle }

struct TabStatus: Identifiable, Equatable {
    let id: String
    let name: String
    let state: TabState
    let note: String // "Do you want to proceed?", "Cerebrating… 39s" or "Idle"
}

final class Dashboard: ObservableObject {
    @Published var tabs: [TabStatus] = []
    @Published var pausedUntil: Date?
    @Published var accessDenied = false
    @Published var claudeConnected = true
    @Published var usage: [Usage] = []
    @Published var update: (version: String, page: URL)? // a newer release, only looked for if Settings says to
    var usageAt = Date.distantPast
    var notch = CGSize.zero
    @Published var leaving = false

    var paused: Bool { (pausedUntil ?? .distantPast) > Date() }
    var waiting: Int { tabs.filter { $0.state == .waiting }.count }
}

// Drops out of the notch when you click it or the menu bar bell: what needs you, what's running, and how much of each plan is left
struct DashboardView: View {
    @ObservedObject var model: Dashboard
    let pick: (String) -> Void
    let pause: (Date?) -> Void
    let editPatterns: () -> Void
    let showSettings: () -> Void
    let openSettings: () -> Void
    let connectClaude: () -> Void
    let disconnectClaude: () -> Void
    let welcome: () -> Void

    // idle tabs are just noise here, only show the ones that need you or are busy
    private var busy: [TabStatus] { model.tabs.filter { $0.state != .idle } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.accessDenied {
                Button(action: openSettings) {
                    Label("Allow Notchy to control your terminal…", systemImage: "exclamationmark.triangle.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain).foregroundStyle(.orange).padding(12)
                Divider()
            }
            if !model.claudeConnected {
                Button(action: connectClaude) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Connect Claude Code", systemImage: "link")
                        Text("Shows the diff or command on each card, and pings you when Claude is done")
                            .font(.notchy(11)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain).foregroundStyle(Look.accent).padding(12)
                Divider()
            }

            if busy.isEmpty {
                Label("Nothing needs you", systemImage: "checkmark.circle")
                    .font(.notchy(12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 18)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(busy) { t in TabRow(tab: t) { pick(t.id) } }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 300)
                .fixedSize(horizontal: false, vertical: true)
            }

            if !model.usage.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.usage) { UsageRow(usage: $0) }
                }
                .padding(12)
            }

            Divider()
            HStack {
                if model.paused {
                    Button(model.pausedUntil == .distantFuture ? "Paused · Resume"
                           : "Paused until \(model.pausedUntil!.formatted(date: .omitted, time: .shortened)) · Resume") { pause(nil) }
                        .foregroundStyle(.orange)
                } else {
                    Menu("Pause") {
                        Button("For 1 hour") { pause(Date().addingTimeInterval(3600)) }
                        Button("Until I resume") { pause(.distantFuture) }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                Spacer()
                Menu {
                    if let u = model.update { Button("Update to \(u.version)…") { NSWorkspace.shared.open(u.page) } }
                    Button("Settings…", action: showSettings)
                    Button("Edit prompt patterns…", action: editPatterns)
                    if !model.claudeConnected { Button("Connect Claude Code", action: connectClaude) }
                    else if ClaudeHooks.added { Button("Disconnect Claude Code", action: disconnectClaude) }
                    Toggle("Open at Login", isOn: Binding(
                        get: { SMAppService.mainApp.status == .enabled },
                        set: { on in try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }))
                    Divider()
                    Button("Welcome to Notchy…", action: welcome)
                    Button("About Notchy") {
                        NSApp.activate()
                        NSApp.orderFrontStandardAboutPanel(nil)
                    }
                    Button("Quit Notchy") { NSApp.terminate(nil) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .buttonStyle(.borderless)
            .font(.notchy(12))
            .padding(10)
        }
        .modifier(NotchChrome(docked: true, notch: model.notch, leaving: model.leaving))
    }
}

struct TabRow: View {
    let tab: TabStatus
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Circle().fill(tab.state == .waiting ? Color.orange : .blue).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tab.name).font(.notchy(12.5, weight: .medium)).lineLimit(1)
                    Text(tab.note).font(.notchy(11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(hover ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(tab.state == .waiting ? "Answer" : "Open the tab")
        .accessibilityLabel("\(tab.name), \(tab.note)")
    }
}

// "Codex  Go" with one thin bar per window:  5-hour ▓▓▓░░░ 38%  resets 3h
struct UsageRow: View {
    let usage: Usage

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(usage.id).font(.notchy(12, weight: .semibold))
                if let plan = usage.plan {
                    Text(plan).font(.notchy(10, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                Spacer()
                if let e = usage.error { Text(e).font(.notchy(11)).foregroundStyle(.secondary) }
            }
            ForEach(usage.limits, id: \.label) { l in
                HStack(spacing: 8) {
                    Text(l.label).frame(width: 50, alignment: .leading).foregroundStyle(.secondary)
                    // drawn by hand, a ProgressView turns grey whenever the dashboard isn't the key window
                    Capsule().fill(Color.primary.opacity(0.1)).frame(height: 5).overlay(alignment: .leading) {
                        GeometryReader { g in
                            Capsule().fill(l.used >= 0.9 ? Color.red : l.used >= 0.7 ? .orange : .green).frame(width: g.size.width * l.used)
                        }
                    }
                    Text("\(Int((l.used * 100).rounded()))%").monospacedDigit().frame(width: 34, alignment: .trailing)
                    Text(l.resetsAt.map { "resets " + short($0) } ?? "").foregroundStyle(.tertiary).frame(width: 64, alignment: .leading)
                }
                .font(.notchy(11))
                .accessibilityElement(children: .combine)
            }
        }
    }

    // 45m, 5h, 3d
    private func short(_ d: Date) -> String {
        let s = max(0, d.timeIntervalSinceNow)
        return s < 3600 ? "\(Int((s / 60).rounded(.up)))m" : s < 172800 ? "\(Int((s / 3600).rounded(.up)))h" : "\(Int((s / 86400).rounded(.up)))d"
    }
}
