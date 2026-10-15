import Foundation

// Run with `make check`. Plain preconditions, if any of these break the detection logic regressed.
@main struct Check {
    static func main() {
        let pats = loadPatterns(defaultPatterns.joined(separator: "\n"))
        func d(_ s: String) -> Prompt? { detectPrompt(screen: s, patterns: pats) }

        precondition(d("building...\nOverwrite config.json? [y/N] \n\n\n") == Prompt(kind: .yesNo, line: "Overwrite config.json? [y/N]"))
        precondition(d("? Install dependencies? (Y/n)") == Prompt(kind: .yesNo, line: "? Install dependencies? (Y/n)"))
        precondition(d("Are you sure you want to continue connecting (yes/no/[fingerprint])? ")?.kind == .yesNo)

        // already answered, or the prompt scrolled up and something else is printing now
        precondition(d("Overwrite config.json? [y/N] y") == nil)
        precondition(d("Overwrite config.json? [y/N] y\ncopying files") == nil)
        // secrets stay in the terminal
        precondition(d("Enter passphrase for key (y/n):") == nil)

        // Claude Code dialog, boxed and unboxed styles
        let boxed = """
        ╭──────────────────────────────╮
        │ Bash command                 │
        │   npm install left-pad       │
        │ Do you want to proceed?      │
        │ ❯ 1. Yes                     │
        │   2. Yes, and don't ask again │
        │   3. No (esc)                │
        ╰──────────────────────────────╯
        """
        precondition(d(boxed) == Prompt(kind: .claude, line: "Do you want to proceed?"))
        let plain = "Edit file\n Do you want to make this edit to main.swift?\n   1. Yes\n ❯ 2. Yes, allow all edits\n   3. No\n\n"
        precondition(d(plain)?.kind == .claude)
        // Claude idle at its input box is not a permission prompt
        precondition(d("> \n  ? for shortcuts") == nil)

        print("all checks passed")
    }
}
