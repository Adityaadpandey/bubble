import AppKit
import SwiftUI

// A floating card in the top-right corner, above every app and full screen spaces.
// It never activates NotiApp, so whatever you were typing in keeps focus until you click the Reply box.
final class PromptPanel: NSPanel {
    override var canBecomeKey: Bool { true } // lets the Reply box take typing

    init(_ card: PromptCard) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false // App holds on to it, AppKit must not free it on close
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        let host = NSHostingView(rootView: card)
        contentView = host
        setContentSize(host.fittingSize)
    }
}

struct Choice: Identifiable { let id, label: String }

struct PromptCard: View {
    let title: String
    let detail: String?   // e.g. "Bash: npm install left-pad"
    let question: String
    let choices: [Choice]
    // (action, reply text), action is a choice id, "reply", "open" or "close"
    let act: (String, String) -> Void
    @State private var reply = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "bell.badge.fill").foregroundStyle(.orange)
                Text(title).font(.headline).lineLimit(1)
                Spacer()
                Button { act("close", "") } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Hide this card, the prompt stays in the terminal")
            }
            if let detail {
                Text(detail).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary).lineLimit(3)
            }
            Text(question).fixedSize(horizontal: false, vertical: true)
            ForEach(choices) { c in
                Button { act(c.id, "") } label: { Text(c.label).frame(maxWidth: .infinity, alignment: .leading) }
                    .buttonStyle(.bordered).controlSize(.large)
            }
            HStack {
                TextField("Reply…", text: $reply).textFieldStyle(.roundedBorder).onSubmit(send)
                Button("Send", action: send).disabled(reply.isEmpty)
            }
            HStack {
                Spacer()
                Button("Open in iTerm2 →") { act("open", "") }.buttonStyle(.link)
            }
        }
        .padding(14)
        .frame(width: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
    }

    func send() { if !reply.isEmpty { act("reply", reply) } }
}
