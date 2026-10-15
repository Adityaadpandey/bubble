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

    var paused: Bool { (pausedUntil ?? .distantPast) > Date() }
    var waiting: Int { tabs.filter { $0.state == .waiting }.count }
}

// The popover under the menu bar bell: every Claude tab and anything waiting on you
struct DashboardView: View {
    @ObservedObject var model: Dashboard
    let pick: (String) -> Void
    let pause: (Date?) -> Void
    let editPatterns: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("NotiApp").font(.system(size: 13, weight: .semibold))
                Spacer()
                if model.paused {
                    Text(model.pausedUntil == .distantFuture ? "Paused" : "Paused until \(model.pausedUntil!.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.2)))
                        .foregroundStyle(.orange)
                }
            }
            .padding(12)
            Divider()

            if model.accessDenied {
                Button(action: openSettings) {
                    Label("Allow NotiApp to control iTerm2…", systemImage: "exclamationmark.triangle.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain).foregroundStyle(.orange).padding(12)
                Divider()
            }

            if model.tabs.isEmpty {
                Text("No Claude tabs or prompts right now")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.tabs) { t in TabRow(tab: t) { pick(t.id) } }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 380)
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack {
                if model.paused {
                    Button("Resume") { pause(nil) }
                } else {
                    Menu("Pause") {
                        Button("For 1 hour") { pause(Date().addingTimeInterval(3600)) }
                        Button("Until I resume") { pause(.distantFuture) }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                Spacer()
                Button("Patterns…", action: editPatterns)
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
            .padding(10)
        }
        .frame(width: 320)
    }
}

struct TabRow: View {
    let tab: TabStatus
    let action: () -> Void
    @State private var hover = false

    private var color: Color {
        switch tab.state {
        case .waiting: return .orange
        case .working: return .blue
        case .idle: return .gray
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Circle().fill(color).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tab.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    Text(tab.note).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(tab.state == .waiting ? "Answer" : "Open")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(hover ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel("\(tab.name), \(tab.note)")
    }
}
