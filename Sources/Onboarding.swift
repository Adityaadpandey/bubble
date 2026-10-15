import AppKit
import Carbon
import ServiceManagement
import SwiftUI

// The first time Notchy opens it drops this out of the notch and walks you through setting up.
// Each macOS permission is asked for only when you click its button, never all at once on launch:
//   Welcome → Your terminal → Claude Code → Usage limits → Done
// The two Claude steps only show up when Claude Code is installed.
final class Onboarding: ObservableObject {
    enum Step { case welcome, terminal, claude, usage, done }
    enum Access { case unknown, asking, allowed, denied }

    let steps: [Step]
    // iTerm2 only if it's installed, Terminal comes with every Mac
    let terminals = [(id: Terminals.iTerm, name: "iTerm2"), (id: Terminals.terminal, name: "Terminal")]
        .filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil }
    @Published var at = 0
    @Published var access: [String: Access] = [:]
    @Published var claudeConnected: Bool
    @Published var leaving = false
    var notch = CGSize.zero

    var step: Step { steps[at] }

    init(claudeInstalled: Bool, claudeConnected: Bool) {
        steps = claudeInstalled ? [.welcome, .terminal, .claude, .usage, .done] : [.welcome, .terminal, .done]
        self.claudeConnected = claudeConnected
        // already allowed (or refused) earlier? Checking without asking never shows a dialog
        for t in terminals { access[t.id] = Self.access(Self.permission(t.id, ask: false)) }
    }

    func next() { at = min(at + 1, steps.count - 1) }

    // macOS can only ask about an app that's running, so a closed one is started quietly in the background
    // first. The dialog blocks until you answer it, so this runs off the main thread.
    func allow(_ app: String) {
        access[app] = .asking
        DispatchQueue.global().async {
            if NSRunningApplication.runningApplications(withBundleIdentifier: app).isEmpty,
               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) {
                let quiet = NSWorkspace.OpenConfiguration()
                quiet.activates = false
                quiet.hides = true
                NSWorkspace.shared.openApplication(at: url, configuration: quiet)
            }
            // an app that's still starting up answers "not running" (-600) for a second or two
            var status = Self.permission(app, ask: true), tries = 0
            while status == OSStatus(procNotFound), tries < 50 {
                Thread.sleep(forTimeInterval: 0.2)
                status = Self.permission(app, ask: true)
                tries += 1
            }
            DispatchQueue.main.async { self.access[app] = Self.access(status) }
        }
    }

    private static func permission(_ app: String, ask: Bool) -> OSStatus {
        AEDeterminePermissionToAutomateTarget(NSAppleEventDescriptor(bundleIdentifier: app).aeDesc, typeWildCard, typeWildCard, ask)
    }

    private static func access(_ status: OSStatus) -> Access {
        status == noErr ? .allowed : status == OSStatus(errAEEventNotPermitted) ? .denied : .unknown
    }
}

struct OnboardingView: View {
    @ObservedObject var model: Onboarding
    let connectClaude: () -> Void
    let showUsage: () -> Void
    let openSettings: () -> Void
    let finish: () -> Void
    @State private var login = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 30, height: 30)
                Text(title).font(.system(size: 16, weight: .semibold))
            }
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            controls
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    ForEach(model.steps.indices, id: \.self) { i in
                        Capsule().fill(Color.primary.opacity(i == model.at ? 0.9 : 0.25))
                            .frame(width: i == model.at ? 14 : 6, height: 6)
                    }
                }
                .accessibilityLabel("Step \(model.at + 1) of \(model.steps.count)")
                Spacer()
                if canSkip {
                    Button("Skip") { model.next() }.buttonStyle(Pill(prominent: false))
                } else if model.step != .done {
                    Button("Later", action: finish).buttonStyle(Pill(prominent: false))
                        .help("Close this. You can open it again from the ⋯ menu.")
                }
                Button(primary.label, action: primary.action).buttonStyle(Pill(prominent: true)).keyboardShortcut(.defaultAction)
            }
            .padding(.top, 2)
        }
        .font(.system(size: 12.5))
        // fixed, so a long sentence wraps instead of stretching the panel out to its widest
        .frame(width: 478, alignment: .leading)
        // the chrome already leaves the notch's height above this, so only a little more on top
        .padding(EdgeInsets(top: 6, leading: 16, bottom: 16, trailing: 16))
        // Esc closes it like Later does, on every step
        .background { Button("", action: finish).keyboardShortcut(.cancelAction).opacity(0) }
        .modifier(NotchChrome(docked: true, notch: model.notch, leaving: model.leaving, smoothResize: true))
        .animation(.easeOut(duration: 0.15), value: model.at)
        // its window is a fixed size, taller than any step, so hang from the top of it
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var title: String {
        switch model.step {
        case .welcome: "Welcome to Notchy"
        case .terminal: "Let Notchy see your terminal"
        case .claude: "Connect Claude Code"
        case .usage: "See how much of your plan is left"
        case .done: "You're all set"
        }
    }

    private var text: String {
        switch model.step {
        case .welcome:
            "When Claude Code or any other CLI stops to ask you something, the question drops out of the notch right here. Click an answer and Notchy types it into the right tab."
        case .terminal:
            "Notchy reads your terminal tabs to spot questions, and types your answers back into them. Nothing leaves your Mac. Click Allow for each one you use, then OK when macOS asks."
        case .claude:
            "Cards then show the exact command or diff you're approving, and Notchy pings you when Claude finishes. This adds two hooks to Claude Code's settings, leaves your other hooks alone, and backs the file up first."
        case .usage:
            "The dashboard shows your 5-hour and weekly limits. For Claude, macOS asks once to let Notchy read Claude Code's login from your Keychain: choose Always Allow. It's only ever sent to Claude's own servers."
        case .done:
            "Hover over the notch any time to see what's waiting, what's running, and how much of each plan is left."
        }
    }

    @ViewBuilder private var controls: some View {
        switch model.step {
        case .terminal:
            VStack(spacing: 6) {
                ForEach(model.terminals, id: \.id) { t in terminalRow(t.id, t.name) }
            }
        case .claude where model.claudeConnected:
            Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .done:
            HStack {
                Text("Open Notchy at login").font(.system(size: 13, weight: .medium))
                Spacer()
                Toggle("Open Notchy at login", isOn: $login).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .onChange(of: login) { _, on in try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        default:
            EmptyView()
        }
    }

    // [icon] iTerm2                 Allow  /  spinner  /  ✓ Allowed  /  Not allowed · Open Settings…
    private func terminalRow(_ id: String, _ name: String) -> some View {
        HStack(spacing: 10) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 22, height: 22)
            }
            Text(name).font(.system(size: 13, weight: .medium))
            Spacer()
            switch model.access[id] ?? .unknown {
            case .unknown: Button("Allow") { model.allow(id) }.buttonStyle(Pill(prominent: false))
            case .asking: ProgressView().controlSize(.small)
            case .allowed: Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .denied:
                Button("Not allowed · Open Settings…", action: openSettings).buttonStyle(.borderless).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
    }

    private var canSkip: Bool {
        model.step == .usage || (model.step == .claude && !model.claudeConnected)
    }

    private var primary: (label: String, action: () -> Void) {
        switch model.step {
        case .welcome: ("Get started", model.next)
        case .claude where !model.claudeConnected:
            ("Connect", { connectClaude(); model.claudeConnected = ClaudeHooks.connected() })
        case .usage: ("Show my limits", { showUsage(); model.next() })
        case .done: ("Finish", finish)
        default: ("Continue", model.next)
        }
    }
}

// Drawn by hand: the system's prominent button turns grey whenever its window isn't the active one,
// which for a panel hanging from the notch is most of the time. Orange for the main one, a light wash for the rest.
struct Pill: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: prominent ? .semibold : .medium))
            .foregroundStyle(prominent ? Color.black : .primary)
            .padding(.horizontal, 14).frame(height: 28)
            .background(Capsule().fill(prominent ? Color.orange : Color.primary.opacity(0.12)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}
