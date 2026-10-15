import Foundation

enum PromptKind: String { case claude, yesNo, idle }

struct Prompt: Equatable {
    let kind: PromptKind
    let line: String
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
/// Claude Code's permission box is spotted anywhere in the last few lines, e.g.
///     Do you want to proceed?
///     ❯ 1. Yes
///       2. Yes, and don't ask again
/// Everything else only counts on the very last line, and only if nothing was typed after it,
/// so "Overwrite? [y/N]" fires but an already answered "Overwrite? [y/N] y" does not.
func detectPrompt(screen: String, patterns: [NSRegularExpression]) -> Prompt? {
    let lines = screen.components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: trimSet) }
        .filter { !$0.isEmpty }
    let tail = lines.suffix(15)

    if let ask = tail.last(where: { $0.hasPrefix("Do you want to") }),
       tail.contains(where: { $0.range(of: #"^(❯\s*)?1\. Yes"#, options: .regularExpression) != nil }) {
        return Prompt(kind: .claude, line: ask)
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
