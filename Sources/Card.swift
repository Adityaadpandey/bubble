import AppKit
import SwiftUI

// What Claude's hook told us about the pending tool call, e.g.
//   title "Edit · main.swift", body "/Users/me/app/main.swift", diff ["- let a = 1", "+ let a = 2"]
struct Detail {
    let title, body: String
    let diff: [String]
    let at = Date()
}

enum CardAction { case answer(Answer), open, close, release }

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
    @Published var failed = false   // the last answer couldn't be typed into iTerm2
    @Published var docked = false   // the top card, hanging from the notch
    @Published var notch = CGSize.zero // the notch's size, so nothing hides behind it and cards can grow out of it
    @Published var leaving = false  // folding back into the notch before the window goes away
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

// A see-through window that hangs from the notch, above the menu bar, every app and full screen spaces.
// It never activates NotiApp, so whatever you were typing in keeps focus until you click into it.
class NotchPanel: NSPanel {
    var dismiss: (() -> Void)? // clicked away or pressed Esc, for windows that should just go away then

    override var canBecomeKey: Bool { true } // lets the reply box and keyboard shortcuts take typing

    init(_ view: NSView, raised: Int = 3) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false // App holds on to it, AppKit must not free it on close
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + raised) // over the menu bar, so it can touch the notch
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false // a window shadow is drawn once at full size and would hang around the notch while the card is folded up
        contentView = view
        setContentSize(view.fittingSize)
    }

    // AppKit nudges windows below the menu bar, but a docked window has to sit right against the top edge
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func resignKey() {
        super.resignKey()
        dismiss?()
    }

    override func cancelOperation(_ sender: Any?) { dismiss?() }
}

final class CardPanel: NotchPanel {
    let host: NSHostingView<CardView>

    init(_ view: CardView) {
        host = NSHostingView(rootView: view)
        super.init(host)
    }

    func fit() { setContentSize(host.fittingSize) }

    // clicked into another app, so the card is no longer listening to the keyboard
    override func resignKey() {
        super.resignKey()
        host.rootView.model.keyboard = false
    }
}

struct CardView: View {
    @ObservedObject var model: CardModel
    let act: (CardAction) -> Void
    @State private var reply = ""
    @FocusState private var replyFocused: Bool
    @FocusState private var cardFocused: Bool

    private var p: Prompt { model.prompt }
    private var isClaude: Bool { p.kind == .menu || p.kind == .idle }
    // Claude's own "Type something" and "Chat about this" rows are what the reply box is for,
    // and unnumbered rows like "Next" get their own button below the choices
    private var visibleRows: [Int] {
        p.rows.indices.filter {
            let r = p.rows[$0]
            return (r.number != nil || p.kind != .menu) && !r.label.hasPrefix("Type something") && r.label != "Chat about this"
        }
    }
    private var navRows: [Int] { p.kind == .menu ? p.rows.indices.filter { p.rows[$0].number == nil } : [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !p.tabs.isEmpty { tabStrip }
            context
            Text(p.line.isEmpty ? "Waiting for you" : p.line)
                .font(.system(size: 14.5, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            if !visibleRows.isEmpty {
                VStack(spacing: 6) {
                    ForEach(Array(visibleRows.enumerated()), id: \.element) { n, i in
                        RowButton(row: p.rows[i], number: n + 1, isCursor: p.kind == .menu && p.cursor == i,
                                  showKey: model.keyboard, destructive: isNo(p.rows[i])) { pick(i) }
                    }
                }
            }
            if p.kind == .list && p.isMulti {
                Button { act(.answer(.submit)) } label: {
                    Label("Submit", systemImage: "checkmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            }
            ForEach(navRows, id: \.self) { i in
                Button { pick(i) } label: {
                    Label(p.rows[i].label, systemImage: "arrow.right").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            }
            if model.failed {
                Label("Couldn't type into iTerm2. Try again, or open the tab.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(.red)
            }
            replyBox
            if model.keyboard { keyboardHint }
        }
        .padding(14)
        .frame(width: 360)
        .disabled(model.waitingOnSend)
        .opacity(model.waitingOnSend ? 0.55 : 1)
        .overlay(alignment: .top) { if model.waitingOnSend { sentBadge } }
        .modifier(NotchChrome(docked: model.docked, notch: model.notch, leaving: model.leaving, outline: model.keyboard ? .accentColor : nil))
        .animation(.easeOut(duration: 0.15), value: model.waitingOnSend)
        .focusable()
        .focusEffectDisabled()
        .focused($cardFocused)
        .onChange(of: model.keyboard) { _, on in cardFocused = on }
        .onKeyPress(action: key)
    }

    // ⌃⌥Space put the keyboard on this card. 1–9 pick, Y/N for yes/no prompts, ←/→ between questions,
    // Return does what Enter does in the terminal, Tab jumps to the reply box, Esc hands the keyboard back.
    private func key(_ press: KeyPress) -> KeyPress.Result {
        guard model.keyboard, !model.waitingOnSend else { return .ignored }
        switch press.key {
        case .escape: act(.release)
        case .tab: replyFocused = true
        case .leftArrow where !p.tabs.isEmpty: act(.answer(.prevTab))
        case .rightArrow where !p.tabs.isEmpty: act(.answer(.nextTab))
        case .return where p.kind == .list && p.isMulti: act(.answer(.submit))
        case .return where p.kind == .text: replyFocused = true
        case .return: pick(navRows.first ?? p.cursor)
        default:
            let c = press.characters.lowercased()
            if let n = Int(c), n >= 1, n <= visibleRows.count { pick(visibleRows[n - 1]) }
            else if p.kind == .yesNo, c == "y" { act(.answer(.yes)) }
            else if p.kind == .yesNo, c == "n" { act(.answer(.no)) }
            else { return .ignored }
        }
        return .handled
    }

    // One quiet line: who's asking, then jump to the tab or hide the card
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: isClaude ? "sparkle" : "terminal")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(isClaude ? Color.orange : .secondary)
            Text(model.title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            iconButton("arrow.up.forward.app", help: "Open in iTerm2") { act(.open) }
            iconButton("xmark", help: "Hide this card, the prompt stays in the terminal") { act(.close) }
        }
    }

    private func iconButton(_ symbol: String, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(.secondary)
        .help(help).accessibilityLabel(help)
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
            TextField(isClaude ? "Reply to Claude…" : p.kind == .list ? "Type to filter or answer…" : "Type an answer…", text: $reply)
                .textFieldStyle(.plain)
                .focused($replyFocused)
                .onSubmit(send)
                .onKeyPress(.escape) { act(.release); return .handled }
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

    private var keyboardHint: some View {
        Text("1–9 pick · Y/N · ←/→ questions · Tab reply · Esc hide")
            .font(.system(size: 10.5)).foregroundStyle(.tertiary)
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
                if showKey {
                    Text("\(number)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .frame(width: 20, height: 20)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.accentColor.opacity(0.25)))
                }
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

// The look every notch window shares, cards and the dashboard alike. Docked, it's a notch-shaped
// glass island, solid black where it meets the notch; otherwise a rounded glass card.
//
// It opens like the notch is stretching: it starts as a black pill exactly the notch's size,
// springs out to full size, and the black melts into glass as the content fades in.
// Setting `leaving` plays that backwards, so it tucks itself back into the notch.
struct NotchChrome: ViewModifier {
    let docked: Bool
    let notch: CGSize
    let leaving: Bool
    var outline: Color? = nil
    @State private var shown = false
    @State private var size = CGSize(width: 380, height: 200)

    private var open: Bool { shown && !leaving }
    private var shape: AnyShape {
        docked ? AnyShape(NotchShape(neck: notch)) : AnyShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    func body(content: Content) -> some View {
        content
            .padding(.top, docked ? notch.height : 0)
            .background { if docked { fade } }
            .glassEffect(.regular.tint(.black.opacity(0.35)), in: shape)
            .overlay { if let outline { shape.stroke(outline, lineWidth: 2) } }
            .environment(\.colorScheme, .dark)
            .overlay { shape.fill(.black).allowsHitTesting(false).opacity(open ? 0 : 1).animation(.easeOut(duration: 0.25).delay(open ? 0.12 : 0), value: open) }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .scaleEffect(x: open ? 1 : min(max(notch.width, 180) / size.width, 1),
                         y: open ? 1 : min(max(notch.height, 24) / size.height, 1), anchor: .top)
            .onAppear { withAnimation(.spring(duration: 0.5, bounce: 0.3)) { shown = true } }
            .animation(.spring(duration: 0.22, bounce: 0), value: leaving)
    }

    // so the notch looks like it stretched open rather than a window sitting under it
    private var fade: some View {
        VStack(spacing: 0) {
            Color.black.frame(height: notch.height)
            LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom).frame(height: 36)
            Spacer(minLength: 0)
        }
        .clipShape(NotchShape(neck: notch))
    }
}

// The outline of a window hanging from the notch. Inside the menu bar it's exactly as wide as the
// notch, so it just looks like the notch got longer, then it curves outward into the card below.
// The menu bar either side stays as it was. Picture the notch pouring into the card:
//
//          │ notch │          <- inside the menu bar, black on black
//     ╭────╯       ╰────╮     <- curves out just under the menu bar
//     │                 │
//     ╰─────────────────╯
struct NotchShape: Shape {
    var neck: CGSize        // the notch it hangs from, e.g. 185 x 32
    var radius: CGFloat = 22
    private let flare: CGFloat = 10

    func path(in rect: CGRect) -> Path {
        let (w, h, r, top) = (rect.width, rect.height, radius, neck.height)
        let f = min(flare, top)
        let left = (w - neck.width) / 2, right = (w + neck.width) / 2
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x, y: rect.minY + y) }
        var p = Path()
        p.move(to: pt(left, 0))
        p.addLine(to: pt(left, top - f))
        p.addQuadCurve(to: pt(left - f, top), control: pt(left, top))
        p.addLine(to: pt(r, top))
        p.addQuadCurve(to: pt(0, top + r), control: pt(0, top))
        p.addLine(to: pt(0, h - r))
        p.addQuadCurve(to: pt(r, h), control: pt(0, h))
        p.addLine(to: pt(w - r, h))
        p.addQuadCurve(to: pt(w, h - r), control: pt(w, h))
        p.addLine(to: pt(w, top + r))
        p.addQuadCurve(to: pt(w - r, top), control: pt(w, top))
        p.addLine(to: pt(right + f, top))
        p.addQuadCurve(to: pt(right, top - f), control: pt(right, top))
        p.addLine(to: pt(right, 0))
        p.closeSubpath()
        return p
    }
}
