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

// One live card per terminal tab. App rewrites `prompt` every tick from the screen,
// so ticking a box or moving to the next question updates this card instead of making a new one.
final class CardModel: ObservableObject {
    let session: String
    let since = Date()
    @Published var title: String
    @Published var place = ""       // "folder · branch" of the project Claude is working in, e.g. "notiapp · main"
    @Published var prompt: Prompt
    @Published var detail: Detail?
    @Published var sent: Prompt?  // what we last answered, the card dims until the screen moves on
    @Published var keyboard = false // focused with ⌃⌥Space
    @Published var failed = false   // the last answer couldn't be typed into the terminal
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
// It never activates Notchy, so whatever you were typing in keeps focus until you click into it.
class NotchPanel: NSPanel {
    var dismiss: (() -> Void)? // clicked away or pressed Esc, for windows that should just go away then

    override var canBecomeKey: Bool { true } // lets the reply box and keyboard shortcuts take typing

    init(_ view: NSView, raised: Int = 3) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false // App holds on to it, AppKit must not free it on close
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + raised) // over the menu bar, so it can touch the notch
        // on every desktop, and stationary so it doesn't slide along with the desktop when you switch
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
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
    @State private var confirming: Int? // the "don't ask again" row clicked once on a risky command

    private var p: Prompt { model.prompt }
    // what's about to run or change, e.g. "$ rm -rf build", checked for the usual footguns
    private var risks: [String] { p.kind == .idle ? [] : riskNotes(([model.detail?.body ?? ""] + p.context).joined(separator: "\n")) }
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
            riskBanner
            Text(p.line.isEmpty ? "Waiting for you" : p.line)
                .font(.notchy(14.5, weight: .semibold))
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
                Label("Couldn't type that into the terminal. Try again, or open the tab.", systemImage: "exclamationmark.triangle.fill")
                    .font(.notchy(12)).foregroundStyle(.red)
            }
            replyBox
            if model.keyboard { keyboardHint }
        }
        .padding(Look.padding)
        .disabled(model.waitingOnSend)
        .opacity(model.waitingOnSend ? 0.55 : 1)
        .overlay(alignment: .top) { if model.waitingOnSend { sentBadge } }
        .modifier(NotchChrome(docked: model.docked, notch: model.notch, leaving: model.leaving, outline: model.keyboard ? Look.accent : nil))
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
                .font(.notchy(11, weight: .bold))
                .foregroundStyle(isClaude ? Color.orange : .secondary)
            Text(model.title).font(.notchy(12, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            if !model.place.isEmpty {
                Text(model.place).font(.notchy(11)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            iconButton("arrow.up.forward.app", help: "Open the tab") { act(.open) }
            iconButton("xmark", help: "Hide this card, the prompt stays in the terminal") { act(.close) }
        }
    }

    private func iconButton(_ symbol: String, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.notchy(11, weight: .semibold)).frame(width: 22, height: 22).contentShape(Rectangle())
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
                    if t.done { Image(systemName: "checkmark").font(.notchy(9, weight: .bold)) }
                    Text(t.label).lineLimit(1)
                }
                .font(.notchy(11, weight: .medium))
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
                    Text(d.title).font(.notchy(11, weight: .semibold)).foregroundStyle(.secondary).padding(.bottom, 2)
                }
                ForEach(Array(lines.prefix(14).enumerated()), id: \.offset) { _, l in
                    Text(l)
                        .font(.notchy(11.5, design: .monospaced))
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

    // Red, between the command and the choices. After a first click on "don't ask again" it asks for a second.
    @ViewBuilder private var riskBanner: some View {
        if !risks.isEmpty {
            Label(confirming == nil ? risks.joined(separator: " · ") : "Risky: click \"don't ask again\" once more to allow this for good",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.notchy(12, weight: .medium))
                .foregroundStyle(Color.red)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.red.opacity(0.14)))
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
                Image(systemName: "arrow.up.circle.fill").font(.notchy(20))
            }
            .buttonStyle(.plain)
            .foregroundStyle(reply.isEmpty ? Color.secondary : Look.accent)
            .disabled(reply.isEmpty)
            .accessibilityLabel("Send reply")
        }
        .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(replyFocused ? 0.3 : 0.12)))
    }

    private var keyboardHint: some View {
        Text("1–9 pick · Y/N · ←/→ questions · Tab reply · Esc hide")
            .font(.notchy(10.5)).foregroundStyle(.tertiary)
    }

    private var sentBadge: some View {
        Label("Sent", systemImage: "checkmark.circle.fill")
            .font(.notchy(12, weight: .semibold))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(Color.green))
            .foregroundStyle(.white)
            .padding(.top, 10)
    }

    private func isNo(_ row: Row) -> Bool { row.label.hasPrefix("No") }

    // "Yes, and don't ask again…" is the row that turns one approval into a standing one
    private func isStanding(_ row: Row) -> Bool { row.label.localizedCaseInsensitiveContains("don't ask again") }

    private func pick(_ i: Int) {
        // on a risky command that one takes two clicks, so a stray tap or a number key can't wave it through for good
        if !risks.isEmpty, p.rows.indices.contains(i), isStanding(p.rows[i]), confirming != i {
            confirming = i
            return
        }
        confirming = nil
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
                        .font(.notchy(11, weight: .semibold, design: .rounded))
                        .frame(width: 20, height: 20)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Look.accent.opacity(0.25)))
                }
                if let checked = row.checked {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .foregroundStyle(checked ? Look.accent : .secondary)
                }
                // Claude's key hints like "(esc)" mean nothing on a card
                Text(row.label.replacingOccurrences(of: #"\s*\((esc|shift\+tab|tab)\)$"#, with: "", options: .regularExpression))
                    .foregroundStyle(destructive ? Color.red : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.notchy(13))
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(hover ? 0.12 : 0.05)))
            // outline = where the ❯ is in the terminal right now
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(isCursor ? Look.accent.opacity(0.6) : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(row.checked == nil ? row.label : "\(row.label), \(row.checked! ? "checked" : "unchecked")")
    }
}

// The look every notch window shares, cards and the dashboard alike: the notch's own black, so the
// notch and the window read as one thing. The docked one is the notch grown bigger, flush with the top
// of the screen with the same little inward curves at the top corners. The rest are black islands below it.
//
// Opening, the black shape starts folded up inside the notch (so you can't see it yet), springs out to
// full size with a tiny bounce, and the content fades in a beat later once there's room for it.
// Closing runs it backwards a little quicker: content out first, then the shape tucks back into the notch.
//
// Every frame is worked out from the clock (see `springOpen`) instead of stacking SwiftUI animations,
// which drifted off centre and let text spill outside the shape halfway through.
struct NotchChrome: ViewModifier {
    let docked: Bool
    let notch: CGSize
    let leaving: Bool
    var outline: Color? = nil
    var smoothResize = false // glide to a new size (onboarding steps) rather than snapping to it
    @State private var openedAt = Date()
    @State private var leftAt: Date?
    @State private var size = CGSize.zero
    @State private var settled = false // done opening, so stop redrawing every frame

    // room around the shape for the spring's overshoot and the shadow, see-through so clicks pass
    static let margin: CGFloat = 14

    // folded up it fits just inside the notch; a screen without one gets a notch-sized starting point
    private var folded: CGSize { CGSize(width: notch.width > 0 ? notch.width : 180, height: notch.height > 0 ? notch.height : 24) }

    func body(content: Content) -> some View {
        TimelineView(.animation(paused: settled && leftAt == nil)) { ctx in
            let opened = ctx.date.timeIntervalSince(openedAt)
            let closing = leftAt.map { ctx.date.timeIntervalSince($0) }
            // Once settled it's simply open. Pausing the clock freezes it on its last frame, so if the window
            // got no frames while opening (Mac busy, app napping) the card used to stay folded inside the notch.
            let done = settled && leftAt == nil
            // grow: 0 = folded in the notch, 1 = full size. reveal: how visible the content is.
            let grow = done ? 1 : closing.map { 1 - smooth($0 / 0.15) } ?? springOpen(opened)
            let reveal = done ? 1 : closing.map { 1 - smooth($0 / 0.06) } ?? smooth((opened - 0.04) / 0.12)
            chrome(content, grow: size == .zero ? 0 : grow, reveal: reveal)
        }
        .padding([.horizontal, .bottom], Self.margin)
        .onChange(of: leaving) { _, now in if now { leftAt = Date() } }
        .task { try? await Task.sleep(for: .seconds(0.6)); settled = true }
    }

    private func chrome(_ content: Content, grow: Double, reveal: Double) -> some View {
        let w = folded.width + (max(size.width, folded.width) - folded.width) * grow
        let h = folded.height + (max(size.height, folded.height) - folded.height) * grow
        let shape = NotchShape(ears: docked, radius: 10 + 16 * min(grow, 1))
        return ClampWidth(min: Look.width.lowerBound, max: Look.width.upperBound) {
            content
                // clear the notch, but the content's own padding already leaves a gap under it, so take 8 off
                // rather than stacking both: 32pt notch + 14pt padding read as a big empty band
                .padding(.top, docked ? max(notch.height - 8, 0) : 0)
                .padding(.horizontal, docked ? NotchShape.ear : 0)
        }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { new in
                if smoothResize, size != .zero { withAnimation(.smooth(duration: 0.3)) { size = new } } else { size = new }
            }
            .environment(\.colorScheme, .dark)
            .opacity(reveal)
            .blur(radius: (1 - reveal) * 8)
            .mask(alignment: .top) { shape.frame(width: w, height: h) } // text never shows outside the black
            .background(alignment: .top) {
                shape.fill(.black).frame(width: w, height: h)
                    .shadow(color: .black.opacity(0.3 * min(grow, 1)), radius: 10, y: 4)
            }
            .overlay(alignment: .top) {
                if let outline { shape.stroke(outline, lineWidth: 2).frame(width: w, height: h) }
            }
    }
}

// As wide as the content would like, kept between `min` and `max`, then as tall as it needs at that width.
// e.g. a short "Overwrite? [y/N]" card stays at 510, a long command grows it up to 720 and wraps after that.
// (A plain .frame(minWidth:maxWidth:) picks the width but measures the height as if nothing wrapped,
// so long text would get cut off.)
struct ClampWidth: Layout {
    let min: CGFloat
    let max: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        let width = Swift.min(Swift.max(view.sizeThatFits(.unspecified).width, min), max)
        return CGSize(width: width, height: view.sizeThatFits(ProposedViewSize(width: width, height: nil)).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

// A quick spring with a small overshoot (under 2%), the same snap as the iPhone's Dynamic Island.
// At 0s it's 0, halfway out by 0.06s, past 1 by 0.16s peaking near 1.02, resting at 1 by 0.3s.
func springOpen(_ t: Double) -> Double {
    guard t > 0 else { return 0 }
    let damping = 0.78, w = 2 * Double.pi / 0.26
    let wd = w * (1 - damping * damping).squareRoot()
    return 1 - exp(-damping * w * t) * (cos(wd * t) + damping * w / wd * sin(wd * t))
}

// 0 to 1 with soft ends, anything outside 0...1 is held at the end
func smooth(_ x: Double) -> Double {
    let x = min(max(x, 0), 1)
    return x * x * (3 - 2 * x)
}

// The notch's outline, stretched. Flush with the top of the screen, a small inward curve at each top
// corner where it meets the menu bar (like the real notch), and rounded corners at the bottom.
//
//   ‾╮                    ╭‾    <- top edge of the screen
//    │                    │
//    ╰────────────────────╯
//
// The bottom corners go from the notch's tight 10pt to a softer 26pt as it opens.
// Without `ears` it's a plain rounded rectangle, for the cards lined up below the notch.
struct NotchShape: Shape {
    static let ear: CGFloat = 8
    var ears = true
    var radius: CGFloat
    var earSize = Self.ear // bigger for the app icon, where 8 would be too small to see

    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        guard ears else { return Path(roundedRect: rect, cornerRadius: radius, style: .continuous) }
        let (w, h, e) = (rect.width, rect.height, earSize)
        let r = max(0, min(radius, (w - 2 * e) / 2, h - e))
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x, y: rect.minY + y) }
        var p = Path()
        p.move(to: pt(0, 0))
        p.addQuadCurve(to: pt(e, e), control: pt(e, 0))
        p.addLine(to: pt(e, h - r))
        p.addQuadCurve(to: pt(e + r, h), control: pt(e, h))
        p.addLine(to: pt(w - e - r, h))
        p.addQuadCurve(to: pt(w - e, h - r), control: pt(w - e, h))
        p.addLine(to: pt(w - e, e))
        p.addQuadCurve(to: pt(w, 0), control: pt(w - e, 0))
        p.closeSubpath()
        return p
    }
}
