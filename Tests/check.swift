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
        precondition(d(boxed) == Prompt(kind: .claude, line: "Do you want to proceed?",
                                         options: ["Yes", "Yes, and don't ask again", "No (esc)"], cursor: 1))
        let plain = "Edit file\n Do you want to make this edit to main.swift?\n   1. Yes\n ❯ 2. Yes, allow all edits\n   3. No\n\n"
        precondition(d(plain)?.cursor == 2)

        // Claude asking a multiple choice question (captured from a real iTerm2 screen)
        let question = """
         ☐ Notifs
        │ Turn on notifications for NotiApp. Done?
        ❯ 1. Done, enabled
             NotiApp notifications are on.
          2. NotiApp isn't listed
             Couldn't find NotiApp in the list.
          3. Type something.
        ─────────────────────────────
          4. Chat about this

        Enter to select · ↑/↓ to navigate · Esc to cancel
        """
        precondition(d(question) == Prompt(kind: .claude, line: "Turn on notifications for NotiApp. Done?",
                                            options: ["Done, enabled", "NotiApp isn't listed", "Type something.", "Chat about this"], cursor: 1))

        // Claude idle at its input box, or a numbered list in its answer, is not a prompt
        precondition(d("❯ \n  ? for shortcuts") == nil)
        precondition(d("Steps:\n1. Build it\n2. Run it\n❯ ") == nil)

        // whatever you type in Reply… must reach the terminal byte for byte, quotes and all
        for text in ["plain", #"say "hi" \ there"#, "\u{1b}[B", "yes\r", "", #"" & do shell script "x" & ""#] {
            var err: NSDictionary?
            let back = NSAppleScript(source: "return \(appleScriptString(text))")?.executeAndReturnError(&err).stringValue
            precondition(back == text, "round trip failed for \(text.debugDescription): \(String(describing: back)) \(String(describing: err))")
        }

        print("all checks passed")
    }
}
