import Foundation

enum PromptKind: String { case claude, yesNo, idle }

struct Prompt: Equatable {
    let kind: PromptKind
    let line: String
    var options: [String] = [] // Claude menus only, e.g. ["Yes", "Yes, and don't ask again", "No"]
    var cursor = 0             // which option (1-based) the ❯ is on right now

    // Same question still waiting, even if you moved the cursor around in the terminal
    func sameAs(_ other: Prompt?) -> Bool { other?.kind == kind && other?.line == line }
}

// Written to ~/.config/notiapp/patterns.txt on first launch, edit that file to teach it new CLIs
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
/// Claude Code menus (permission dialogs and its multiple choice questions) are spotted
/// anywhere in the last few lines: a ❯ cursor sitting on a numbered list, e.g.
///     Do you want to proceed?
///     ❯ 1. Yes
///       2. Yes, and don't ask again
/// The line right above "1." is the question.
/// Everything else only counts on the very last line, and only if nothing was typed after it,
/// so "Overwrite? [y/N]" fires but an already answered "Overwrite? [y/N] y" does not.
func detectPrompt(screen: String, patterns: [NSRegularExpression]) -> Prompt? {
    let lines = screen.components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: trimSet) }
        .filter { !$0.isEmpty }

    var options: [String] = [], cursor = 0, question = "", previous = ""
    for l in lines.suffix(25) {
        guard let m = l.wholeMatch(of: #/(❯\s*)?(\d+)\.\s+(.+)/#), let n = Int(m.2) else { previous = l; continue }
        if n == 1 { options = []; cursor = 0; question = previous }
        guard n == options.count + 1 else { continue } // a stray "7." in the description lines
        options.append(String(m.3))
        if m.1 != nil { cursor = n }
    }
    if options.count >= 2, cursor > 0 {
        return Prompt(kind: .claude, line: question, options: options, cursor: cursor)
    }

    guard let last = lines.last else { return nil }
    // Never push password prompts into Notification Center
    if last.range(of: "pass(word|phrase|code)", options: [.regularExpression, .caseInsensitive]) != nil { return nil }

    let ns = last as NSString
    for re in patterns {
        guard let m = re.firstMatch(in: last, range: NSRange(location: 0, length: ns.length)) else { continue }
        let rest = ns.substring(from: m.range.upperBound)
        if rest.trimmingCharacters(in: CharacterSet(charactersIn: " :?>")).isEmpty {
            return Prompt(kind: .yesNo, line: last)
        }
    }
    return nil
}

func loadPatterns(_ text: String) -> [NSRegularExpression] {
    text.components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        .compactMap { try? NSRegularExpression(pattern: $0) }
}

// AppleScript strings can't hold control keys, so "\u{1b}[B" becomes ((character id 27) & "[B")
// and Return goes in as (character id 13)
func appleScriptString(_ s: String) -> String {
    var parts: [String] = [], chunk = ""
    func flush() {
        if !chunk.isEmpty { parts.append("\"" + chunk.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"") }
        chunk = ""
    }
    for u in s.unicodeScalars {
        if u == "\u{1b}" || u == "\r" { flush(); parts.append("(character id \(u.value))") } else { chunk.unicodeScalars.append(u) }
    }
    flush()
    return parts.isEmpty ? "\"\"" : "(" + parts.joined(separator: " & ") + ")"
}
