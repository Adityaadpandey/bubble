import AppKit
import SwiftUI

// What Claude's hook told us about the pending tool call, e.g.
//   title "Edit · main.swift", body "/Users/me/app/main.swift", diff ["- let a = 1", "+ let a = 2"]
struct Detail {
    let title, body: String
    let diff: [String]
    let at = Date()
}

enum CardAction { case answer(Answer), open, close }

// One live card per iTerm2 tab. App rewrites `prompt` every tick from the screen,
// so ticking a box or moving to the next question updates this card instead of making a new one.
final class CardModel: ObservableObject {
    let session: String
    let since = Date()
    @Published var title: String
    @Published var prompt: Prompt
    @Published var detail: Detail?
    @Published var sent: Prompt?  // what we last answered, the card dims until the screen moves on
    @Published var keyboard = false // focused with ⌃⌥Space
    var snapshot = ""
    var sentAt = Date.distantPast
    var repinged = false

    init(session: String, title: String, prompt: Prompt, detail: Detail?) {
        self.session = session
        self.title = title
        self.prompt = prompt
        self.detail = detail
    }

    var waitingOnSend: Bool { sent == prompt }
}

// A floating card in the top-right corner, above every app and full screen spaces.
// It never activates NotiApp, so whatever you were typing in keeps focus until you click into the card.
final class CardPanel: NSPanel {
    let host: NSHostingView<CardView>

    override var canBecomeKey: Bool { true } // lets the reply box and keyboard shortcuts take typing

    init(_ view: CardView) {
        host = NSHostingView(rootView: view)
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false // App holds on to it, AppKit must not free it on close
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        contentView = host
        fit()
    }

    func fit() { setContentSize(host.fittingSize) }
}

struct CardView: View {
    @ObservedObject var model: CardModel
    let act: (CardAction) -> Void
    @State private var reply = ""
    @FocusState private var replyFocused: Bool

    private var p: Prompt { model.prompt }
    private var isClaude: Bool { p.kind != .yesNo }
    // Claude's own "Type something" and "Chat about this" rows are what the reply box is for,
    // and unnumbered rows like "Next" get their own button below the choices
    private var visibleRows: [Int] {
        p.rows.indices.filter {
            let r = p.rows[$0]
            return (r.number != nil || p.kind == .yesNo) && !r.label.hasPrefix("Type something") && r.label != "Chat about this"
        }
    }
    private var navRows: [Int] { p.kind == .menu ? p.rows.indices.filter { p.rows[$0].number == nil } : [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !p.tabs.isEmpty { tabStrip }
            context
            Text(p.line.isEmpty ? "Waiting for you" : p.line)
                .font(.system(size: 14, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            if !visibleRows.isEmpty {
                VStack(spacing: 6) {
                    ForEach(Array(visibleRows.enumerated()), id: \.element) { n, i in
                        RowButton(row: p.rows[i], number: n + 1, isCursor: p.kind == .menu && p.cursor == i,
                                  showKey: model.keyboard, destructive: isNo(p.rows[i])) { pick(i) }
                    }
                }
            }
            ForEach(navRows, id: \.self) { i in
                Button { pick(i) } label: {
                    Label(p.rows[i].label, systemImage: "arrow.right").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            }
            replyBox
            footer
        }
        .padding(16)
        .frame(width: 380)
        .disabled(model.waitingOnSend)
        .opacity(model.waitingOnSend ? 0.55 : 1)
        .overlay(alignment: .top) { if model.waitingOnSend { sentBadge } }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(model.keyboard ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: model.keyboard ? 2 : 1)
        )
        .animation(.easeOut(duration: 0.15), value: model.waitingOnSend)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: isClaude ? "sparkle" : "terminal")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isClaude ? Color.orange : Color.gray))
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                HStack(spacing: 4) {
                    Text(kindLabel)
                    Text("·")
                    Text(model.since, style: .relative)
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { act(.close) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 20, height: 20)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help("Hide this card, the prompt stays in the terminal")
            .accessibilityLabel("Hide")
        }
    }

    private var kindLabel: String {
        switch p.kind {
        case .idle: return "Waiting for your next message"
        case .yesNo: return "Asking yes or no"
        case .menu where p.isMulti: return "Pick one or more"
        case .menu where model.detail != nil || p.line.hasPrefix("Do you want"): return "Needs your permission"
        case .menu: return "Asking a question"
        }
    }

    // Several questions at once: ✓ for answered ones, arrows to move between them
    private var tabStrip: some View {
        HStack(spacing: 6) {
            Button { act(.answer(.prevTab)) } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
            ForEach(p.tabs, id: \.label) { t in
                HStack(spacing: 3) {
                    if t.done { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
                    Text(t.label).lineLimit(1)
                }
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(t.done ? Color.green.opacity(0.18) : Color.primary.opacity(0.07)))
                .foregroundStyle(t.done ? Color.green : .secondary)
            }
            Button { act(.answer(.nextTab)) } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless)
        }
    }

    // The command, or the before/after of an edit, so you know what you're approving
    @ViewBuilder private var context: some View {
        let lines = model.detail.map { [$0.body].filter { !$0.isEmpty } + $0.diff } ?? p.context
        if model.detail != nil || !lines.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                if let d = model.detail {
                    Text(d.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.bottom, 2)
                }
                ForEach(Array(lines.prefix(14).enumerated()), id: \.offset) { _, l in
                    Text(l)
                        .font(.system(size: 11.5, design: .monospaced))
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .background(l.hasPrefix("+ ") ? Color.green.opacity(0.15) : l.hasPrefix("- ") ? Color.red.opacity(0.15) : .clear)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
            .textSelection(.enabled)
        }
    }

    private var replyBox: some View {
        HStack(spacing: 8) {
            TextField(isClaude ? "Reply to Claude…" : "Type an answer…", text: $reply)
                .textFieldStyle(.plain)
                .focused($replyFocused)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 20))
            }
            .buttonStyle(.plain)
            .foregroundStyle(reply.isEmpty ? Color.secondary : Color.accentColor)
            .disabled(reply.isEmpty)
            .accessibilityLabel("Send reply")
        }
        .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(replyFocused ? 0.3 : 0.12)))
    }

    private var footer: some View {
        HStack {
            Text(model.keyboard ? "1–9 pick · Y/N · ←/→ questions · Tab reply · Esc hide" : "⌃⌥Space to answer by keyboard")
                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
            Spacer()
            Button("Open in iTerm2 ↗") { act(.open) }.buttonStyle(.link).font(.system(size: 11.5))
        }
    }

    private var sentBadge: some View {
        Label("Sent", systemImage: "checkmark.circle.fill")
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(Color.green))
            .foregroundStyle(.white)
            .padding(.top, 10)
    }

    private func isNo(_ row: Row) -> Bool { row.label.hasPrefix("No") }

    private func pick(_ i: Int) {
        if p.kind == .yesNo { act(.answer(i == 0 ? .yes : .no)) } else { act(.answer(.pick(i))) }
    }

    private func send() {
        guard !reply.isEmpty else { return }
        act(.answer(.reply(reply)))
        reply = ""
    }
}

struct RowButton: View {
    let row: Row
    let number: Int
    let isCursor: Bool
    let showKey: Bool
    let destructive: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text("\(number)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .frame(width: 20, height: 20)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(showKey ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.08)))
                if let checked = row.checked {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .foregroundStyle(checked ? Color.accentColor : .secondary)
                }
                // Claude's key hints like "(esc)" mean nothing on a card
                Text(row.label.replacingOccurrences(of: #"\s*\((esc|shift\+tab|tab)\)$"#, with: "", options: .regularExpression))
                    .foregroundStyle(destructive ? Color.red : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(hover ? 0.12 : 0.05)))
            // outline = where the ❯ is in the terminal right now
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(isCursor ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(row.checked == nil ? row.label : "\(row.label), \(row.checked! ? "checked" : "unchecked")")
    }
}
