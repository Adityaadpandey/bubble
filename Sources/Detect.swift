import Foundation

// menu: Claude's numbered menus, list: other CLIs' arrow-key lists, text: a CLI asking for typed input
enum PromptKind: String { case menu, list, yesNo, text, idle }

struct Row: Equatable {
    let label: String
    var number: Int? = nil   // the "3." in Claude menus, nil for rows like "Next"
    var checked: Bool? = nil // nil when the row isn't a checkbox
}

// One question in a Claude multi-question prompt, from the strip "←  ☒ Alerts  ☐ Keyboard  ✔ Submit  →"
struct QuestionTab: Equatable {
    let label: String
    let done: Bool
}

struct Prompt: Equatable {
    let kind: PromptKind
    let line: String          // the question itself
    var rows: [Row] = []
    var cursor = 0            // which row the ❯ is on right now
    var tabs: [QuestionTab] = []
    var context: [String] = [] // what sits above the question, e.g. "Bash command" / "npm install left-pad"

    var isMulti: Bool { rows.contains { $0.checked != nil } }
}

// Written to ~/.config/bubble/patterns.txt on first launch, edit that file to teach it new CLIs
let defaultPatterns = [
    #"\[[yY]/[nN]\]"#,          // Overwrite? [y/N]
    #"\([yY]/[nN]\)"#,          // ? Continue (Y/n)
    #"\[[yY]es/[nN]o\]"#,       // Proceed [yes/no]
    #"\(yes/no(/\[fingerprint\])?\)"#, // ssh: Are you sure you want to continue connecting (yes/no/[fingerprint])?
]

// Box-drawing chars Claude Code (and friends) wrap their dialogs in, stripped so "│ ❯ 1. Yes │" reads as "❯ 1. Yes"
private let trimSet = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "│┃|╭╮╰╯─━"))

/// Looks at the bottom of a terminal screen and says whether something is waiting on you.
///
/// Claude Code menus (permission dialogs, its questions, multi-select, multi-question) are a ❯ cursor
/// somewhere in a numbered list near the bottom, with the question on the line right above "1.":
///     ←  ☒ Alerts  ☐ Keyboard  ✔ Submit  →
///     Smarter alerts: which of these do you want?
///     ❯ 1. [✔] Confirmation toast
///       2. [ ] Re-ping if ignored
///          Next
/// Arrow-key lists from other CLIs (inquirer, clack, prompts) are found by their cursor row, see `cliList`.
/// Yes/no only counts on the very last line, and only if nothing was typed after it,
/// so "Overwrite? [y/N]" fires but an already answered "Overwrite? [y/N] y" does not.
/// Free-text questions ("? Project name:", "Enter the API URL:") need the screen to have sat still
/// for `quietFor` seconds, since a line ending in ":" could just be output still on its way.
func detectPrompt(screen: String, patterns: [NSRegularExpression], quietFor: TimeInterval = 0) -> Prompt? {
    let raw = screen.components(separatedBy: .newlines)
    // a line made only of ─ is a divider, kept as "" so context stops there
    let all = raw.map { $0.contains("──") && $0.trimmingCharacters(in: trimSet).isEmpty ? "" : $0.trimmingCharacters(in: trimSet) }
    let lines = all.enumerated().filter { !$0.element.isEmpty || raw[$0.offset].contains("──") }.map(\.element)

    if let menu = claudeMenu(Array(lines.suffix(40))) { return menu }
    if let list = cliList(raw) { return list }

    guard let last = lines.last(where: { !$0.isEmpty }) else { return nil }
    // Never push password prompts onto the screen
    if last.range(of: "pass(word|phrase|code)", options: [.regularExpression, .caseInsensitive]) != nil { return nil }

    let ns = last as NSString
    for re in patterns {
        guard let m = re.firstMatch(in: last, range: NSRange(location: 0, length: ns.length)) else { continue }
        let rest = ns.substring(from: m.range.upperBound)
        if rest.trimmingCharacters(in: CharacterSet(charactersIn: " :?>")).isEmpty {
            return Prompt(kind: .yesNo, line: last, rows: [Row(label: "Yes"), Row(label: "No")])
        }
    }

    let asks = last.hasPrefix("? ") || last.hasSuffix("?")
        || (last.hasSuffix(":") && last.range(of: #"\b(enter|type|name|value|choose|select|input|provide|specify|what|which)\b"#,
                                             options: [.regularExpression, .caseInsensitive]) != nil)
    if quietFor >= 3, asks {
        return Prompt(kind: .text, line: last.hasPrefix("? ") ? String(last.dropFirst(2)) : last)
    }
    return nil
}

/// Arrow-key lists other CLIs draw, found by the cursor row and the rows lined up with it:
///     ? Which framework? (Use arrow keys)       ◆  Pick a project type.       ? Pick toppings
///     ❯ React                                   │  ○ JavaScript               ◉ Cheese
///       Vue                                     │  ● TypeScript              ❯◯ Ham
/// The line above the rows has to read like a question, so quoted "> text" in some output doesn't count.
private func cliList(_ raw: [String]) -> Prompt? {
    // clack draws a │ rail down the left, blank it so the columns still line up
    var tail = raw.suffix(25).map { String($0.replacingOccurrences(of: "│", with: " ").reversed().drop { $0 == " " }.reversed()) }
    while let l = tail.last, l.trimmingCharacters(in: .whitespaces).isEmpty || l.trimmingCharacters(in: .whitespaces) == "└" {
        tail.removeLast()
    }
    guard let c = tail.lastIndex(where: { $0.firstMatch(of: #/^\s*([❯›>]|●\s)/#) != nil }), c >= tail.count - 4 else { return nil }

    // where the option text starts on the cursor row, the other rows start in the same column
    let cur = Array(tail[c])
    var col = cur.firstIndex { $0 != " " }!
    if cur[col] != "●" {
        col += 1
        while col < cur.count, cur[col] == " " { col += 1 }
    }
    guard col < cur.count else { return nil }
    let symbols = Set("◯◉○●◻◼☐☑✔✓[(")
    func isRow(_ i: Int) -> Bool {
        if i == c { return true }
        let l = Array(tail[i])
        guard l.count > col, l[..<col].allSatisfy({ $0 == " " }), l[col] != " " else { return false }
        return !symbols.contains(cur[col]) || symbols.contains(l[col])
    }
    var lo = c, hi = c
    while lo > 0, isRow(lo - 1) { lo -= 1 }
    while hi < tail.count - 1, isRow(hi + 1) { hi += 1 }
    guard hi > lo, lo > 0 else { return nil }

    var question = tail[lo - 1].trimmingCharacters(in: .whitespaces)
    guard question.range(of: #"^[?◆◇]|›|\?$|\?\s*\(|select|choose|pick"#, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
    // "? Which framework? (Use arrow keys)" reads as "Which framework?"
    question = question.replacingOccurrences(of: #"^[?◆◇]\s*"#, with: "", options: .regularExpression)
    question = question.replacingOccurrences(of: #"\s+(›.*|\(.*)$"#, with: "", options: .regularExpression)

    let rows = (lo...hi).map { i -> Row in
        let text = String(Array(tail[i])[col...]).trimmingCharacters(in: .whitespaces)
        if let m = text.wholeMatch(of: #/(?:[◉◼☑✔✓]|\[[xX✔]\]|\(\*\))\s*(.+)/#) { return Row(label: String(m.1), checked: true) }
        if let m = text.wholeMatch(of: #/(?:[◯◻☐]|\[ \]|\( \))\s*(.+)/#) { return Row(label: String(m.1), checked: false) }
        if let m = text.wholeMatch(of: #/[●○]\s*(.+)/#) { return Row(label: String(m.1)) }
        return Row(label: text)
    }
    return Prompt(kind: .list, line: question, rows: rows, cursor: c - lo)
}

private func claudeMenu(_ lines: [String]) -> Prompt? {
    var rows: [Row] = [], cursor = -1, questionAt = -1, started = false

    for (i, l) in lines.enumerated() {
        if let m = l.wholeMatch(of: #/(❯\s*)?(\d+)\.\s+(.+)/#), let n = Int(m.2) {
            if n == 1 { rows = []; cursor = -1; started = true; questionAt = i - 1 }
            // skip a stray "7." inside a description line
            guard started, n == (rows.compactMap(\.number).last ?? 0) + 1 else { continue }
            var label = String(m.3), checked: Bool? = nil
            if let box = label.wholeMatch(of: #/\[(.)\]\s*(.+)/#) {
                checked = box.1 != " "
                label = String(box.2)
            }
            if m.1 != nil { cursor = rows.count }
            rows.append(Row(label: label, number: n, checked: checked))
        } else if started, let m = l.wholeMatch(of: #/(❯\s*)?(Next|Submit)/#) {
            // multi-select has an unnumbered "Next" row the cursor can sit on
            if m.1 != nil { cursor = rows.count }
            rows.append(Row(label: String(m.2)))
        }
    }
    guard rows.filter({ $0.number != nil }).count >= 2, cursor >= 0, questionAt >= 0 else { return nil }

    // Walk up from the question collecting context, until a divider
    var context: [String] = [], tabs: [QuestionTab] = []
    for l in lines[..<questionAt].reversed() {
        if l.isEmpty { break }
        if let strip = l.wholeMatch(of: #/←\s+(.+?)\s+→/#) {
            tabs = String(strip.1).components(separatedBy: "  ").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { QuestionTab(label: String($0.dropFirst()).trimmingCharacters(in: .whitespaces), done: $0.hasPrefix("☒")) }
            break
        }
        if l.hasPrefix("☐") || l.hasPrefix("☒") { break } // the "☐ Notifs" chip on single questions
        context.insert(l, at: 0)
        if context.count == 4 { break }
    }
    return Prompt(kind: .menu, line: lines[questionAt], rows: rows, cursor: cursor, tabs: tabs, context: context)
}

enum Answer: Equatable {
    case pick(Int)        // row index, toggles it in a multi-select
    case submit           // done ticking boxes in a CLI checkbox list
    case yes, no
    case reply(String)
    case prevTab, nextTab // Claude multi-question

    var movesBetweenQuestions: Bool { self == .prevTab || self == .nextTab }
}

/// The keystrokes that answer `p`, sent one chunk at a time `gap` seconds apart.
/// Picking walks the ❯ from where it is now, e.g. cursor on row 0 and pick(2) is ↓ ↓ Enter.
func keys(for a: Answer, in p: Prompt) -> (keys: [String], gap: Double) {
    let down = "\u{1b}[B", up = "\u{1b}[A", esc = "\u{1b}"
    func walk(to i: Int) -> [String] { Array(repeating: i > p.cursor ? down : up, count: abs(i - p.cursor)) }

    switch a {
    // CLI checkbox lists toggle with Space and submit with Enter, Claude's toggle with Enter
    case .pick(let i): return (walk(to: i) + [p.kind == .list && p.isMulti ? " " : "\r"], 0.05)
    case .submit: return (["\r"], 0)
    case .yes: return (["y\r"], 0)
    case .no: return (["n\r"], 0)
    case .prevTab: return (["\u{1b}[D"], 0)
    case .nextTab: return (["\u{1b}[C"], 0)
    case .reply(let text):
        guard p.kind == .menu else { return ([text + "\r"], 0) }
        // Claude questions have a "Type something" row that turns into a text box, so answer there
        if let i = p.rows.firstIndex(where: { $0.label.hasPrefix("Type something") }) {
            return (walk(to: i) + [text, "\r"], 0.05)
        }
        // permission dialogs don't, so back out with Esc and tell Claude once its input box is back
        return ([esc, text + "\r"], 0.6)
    }
}

/// The same answer for a Terminal.app tab, which can only type one line and then press Enter (its `do script`).
/// So it goes as a single line, e.g. "y" for a yes, or "3" to pick row 3 of a Claude menu outright,
/// and Terminal adds the Enter. Nil when it needs a key with no Enter after it (Space to tick a box,
/// ← → between questions), since there's no way to send that.
func terminalLine(for a: Answer, in p: Prompt) -> String? {
    switch a {
    case .pick(let i) where i == p.cursor && !(p.kind == .list && p.isMulti): return ""
    // Claude menus jump straight to a row by its number. Not on multi-question ones, where the number
    // already moves on to the next question and Terminal's Enter would answer that one too.
    case .pick(let i) where p.kind == .menu: return p.tabs.isEmpty && !p.isMulti ? p.rows[i].number.map(String.init) : nil
    // other CLIs read a burst of keys one key at a time (Node's readline does), so ↓ ↓ then Enter is fine
    case .pick where !p.isMulti: return keys(for: a, in: p).keys.dropLast().joined()
    case .submit: return ""
    case .yes: return "y"
    case .no: return "n"
    case .reply(let text) where p.kind != .menu: return text
    default: return nil
    }
}

func loadPatterns(_ text: String) -> [NSRegularExpression] {
    text.components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        .compactMap { try? NSRegularExpression(pattern: $0) }
}

/// What Claude is busy with, from its spinner line, e.g.
/// "✽ Cerebrating… (39s · ↓ 3.1k tokens)" gives "Cerebrating… 39s". Nil when it isn't working.
func claudeActivity(_ screen: String) -> String? {
    for l in screen.components(separatedBy: .newlines).suffix(15).reversed() {
        if let m = l.firstMatch(of: #/^\s*\S\s+([A-Z][\w ]*…)\s*\((\d+[sm][^·)]*)/#) {
            return "\(m.1) \(m.2.trimmingCharacters(in: .whitespaces))"
        }
    }
    return nil
}

/// The last few lines of what a tool said before it stopped, for the "finished" card, e.g. for
///     ⏺ Added the settings window.
///       Files: Settings.swift, Prefs.swift
///     ────────────────
///     ❯
///     ────────────────
///       ? for shortcuts
/// that's ["Added the settings window.", "Files: Settings.swift, Prefs.swift"]. The input box and everything below
/// it are skipped, found by the line of ─ that sits above it, and a screen with none just uses its last lines.
func finishedSummary(screen: String, lines count: Int = 3) -> [String] {
    let raw = screen.components(separatedBy: .newlines)
    let isDivider = { (l: String) in l.contains("──") && l.trimmingCharacters(in: trimSet).isEmpty }
    // the divider above the input box is the last one that has text above it, walking up from the bottom
    var end = raw.count
    var dividers = raw.indices.filter { isDivider(raw[$0]) }
    if dividers.count >= 2 { dividers.removeLast(); end = dividers.last ?? end }
    else if let only = dividers.first { end = only }
    return raw[..<end].map { $0.trimmingCharacters(in: trimSet) }
        .filter { !$0.isEmpty }
        .suffix(count)
        .map { String($0.replacingOccurrences(of: #"^[⏺●•]\s*"#, with: "", options: .regularExpression).prefix(140)) }
}
