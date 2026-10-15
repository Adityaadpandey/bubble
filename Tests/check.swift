import Foundation

// Run with `make check`. Plain preconditions, if any of these break the detection logic regressed.
@main struct Check {
    static func main() {
        let pats = loadPatterns(defaultPatterns.joined(separator: "\n"))
        func d(_ s: String) -> Prompt? { detectPrompt(screen: s, patterns: pats) }

        // CLI yes/no prompts
        precondition(d("building...\nOverwrite config.json? [y/N] \n\n\n")?.line == "Overwrite config.json? [y/N]")
        precondition(d("? Install dependencies? (Y/n)")?.kind == .yesNo)
        precondition(d("Are you sure you want to continue connecting (yes/no/[fingerprint])? ")?.kind == .yesNo)
        // already answered, or the prompt scrolled up and something else is printing now
        precondition(d("Overwrite config.json? [y/N] y") == nil)
        precondition(d("Overwrite config.json? [y/N] y\ncopying files") == nil)
        // secrets stay in the terminal
        precondition(d("Enter passphrase for key (y/n):") == nil)

        // Claude permission dialog, boxed style
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
        let perm = d(boxed)!
        precondition(perm.kind == .menu && perm.line == "Do you want to proceed?" && perm.cursor == 0)
        precondition(perm.rows.map(\.label) == ["Yes", "Yes, and don't ask again", "No (esc)"])
        precondition(perm.context == ["Bash command", "npm install left-pad"])
        precondition(d("Edit file\n Do you want to make this edit to main.swift?\n   1. Yes\n ❯ 2. Yes, allow all edits\n   3. No\n\n")?.cursor == 1)

        // Claude multi-question, multi-select (captured from a real iTerm2 screen, cursor on Next)
        let multi = """
        ⏺ Answer this one in the terminal, not the card.
        ────────────────────────────────────────
        ←  ☒ Alerts  ☐ Keyboard  ✔ Submit  →
        Smarter alerts: which of these do you want?
          1. [✔] Confirmation toast
                 Card turns into a small 'Approved ✓' for a second.
          2. [ ] Re-ping if ignored
                 Sound again if a prompt is still unanswered after 2 minutes.
          3. [ ] Type something
        ❯    Next
        ────────────────────────────────────────
          4. Chat about this
        Enter to select · Tab/Arrow keys to navigate · Esc to cancel
        """
        let m = d(multi)!
        precondition(m.line == "Smarter alerts: which of these do you want?")
        precondition(m.rows.map(\.label) == ["Confirmation toast", "Re-ping if ignored", "Type something", "Next", "Chat about this"])
        precondition(m.rows.map(\.checked) == [true, false, false, nil, nil] && m.isMulti)
        precondition(m.cursor == 3, "cursor sits on Next")
        precondition(m.tabs == [QuestionTab(label: "Alerts", done: true), QuestionTab(label: "Keyboard", done: false), QuestionTab(label: "Submit", done: false)])
        precondition(m.context.isEmpty, "the transcript above the divider is not context")

        // single choice with the "☐ Notifs" chip
        let single = "☐ Notifs\nTurn on notifications. Done?\n❯ 1. Done, enabled\n     Notifications are on.\n  2. Not listed\n  3. Type something.\n"
        precondition(d(single)?.line == "Turn on notifications. Done?" && d(single)?.context == [])

        // Claude idle at its input box, or a numbered list in its answer, is not a prompt
        precondition(d("❯ \n  ? for shortcuts") == nil)
        precondition(d("Steps:\n1. Build it\n2. Run it\n❯ ") == nil)
        precondition(d("❯ 1. but this is me typing into Claude's input box") == nil)

        // answering: walk the cursor, toggle, reply into "Type something", tabs
        precondition(keys(for: .pick(0), in: perm).keys == ["\r"])
        precondition(keys(for: .pick(2), in: perm).keys == ["\u{1b}[B", "\u{1b}[B", "\r"])
        precondition(keys(for: .pick(1), in: m).keys == ["\u{1b}[A", "\u{1b}[A", "\r"])
        precondition(keys(for: .reply("hi"), in: m).keys == ["\u{1b}[A", "hi", "\r"])
        precondition(keys(for: .reply("no, use pnpm"), in: perm) == (["\u{1b}", "no, use pnpm\r"], 0.6))
        precondition(keys(for: .nextTab, in: m).keys == ["\u{1b}[C"])
        let yn = d("Overwrite? [y/N]")!
        precondition(keys(for: .yes, in: yn).keys == ["y\r"] && keys(for: .reply("maybe"), in: yn).keys == ["maybe\r"])

        // generic CLI lists: inquirer select, inquirer checkbox, clack select, prompts select
        let inq = d("? Which framework? (Use arrow keys)\n❯ React\n  Vue\n  Svelte\n")!
        precondition(inq.kind == .list && inq.line == "Which framework?" && inq.rows.map(\.label) == ["React", "Vue", "Svelte"] && inq.cursor == 0)
        let box = d("? Pick toppings (Press <space> to select, <a> to toggle all)\n ◉ Cheese\n❯◯ Ham\n ◯ Olives")!
        precondition(box.kind == .list && box.isMulti && box.cursor == 1 && box.rows.map(\.checked) == [true, false, false])
        precondition(box.rows.map(\.label) == ["Cheese", "Ham", "Olives"] && box.line == "Pick toppings")
        let clack = d("┌  create-app\n│\n◆  Pick a project type.\n│  ○ JavaScript\n│  ● TypeScript\n└\n")!
        precondition(clack.kind == .list && clack.cursor == 1 && !clack.isMulti && clack.line == "Pick a project type.")
        let prm = d("? Pick a color › - Use arrow-keys. Return to submit.\n❯   Red\n    Green\n    Blue")!
        precondition(prm.line == "Pick a color" && prm.rows.count == 3)
        // a shell prompt with a command typed into it, or quoted text, is not a list
        precondition(d("~/proj on main\n❯ npm run build\n") == nil)
        precondition(d("Notes:\n> first quote\n  continued") == nil)

        // answering lists: Enter picks, Space toggles a checkbox, Enter submits
        precondition(keys(for: .pick(2), in: inq).keys == ["\u{1b}[B", "\u{1b}[B", "\r"])
        precondition(keys(for: .pick(0), in: box).keys == ["\u{1b}[A", " "])
        precondition(keys(for: .submit, in: box).keys == ["\r"])

        // free-text questions only count once the screen has been still for a few seconds
        let name = "? Project name: (my-app) "
        precondition(detectPrompt(screen: name, patterns: pats, quietFor: 1) == nil)
        precondition(detectPrompt(screen: name, patterns: pats, quietFor: 5)?.kind == .text)
        precondition(detectPrompt(screen: "Enter the API base URL:", patterns: pats, quietFor: 5)?.line == "Enter the API base URL:")
        precondition(detectPrompt(screen: "Running tests:", patterns: pats, quietFor: 5) == nil, "a label, not a question")
        precondition(detectPrompt(screen: "Enter your password:", patterns: pats, quietFor: 5) == nil)
        precondition(detectPrompt(screen: "aditya@mac notiapp % ", patterns: pats, quietFor: 60) == nil)
        precondition(keys(for: .reply("my-app"), in: detectPrompt(screen: name, patterns: pats, quietFor: 5)!).keys == ["my-app\r"])

        // dashboard status from Claude's spinner
        precondition(claudeActivity("⏺ done\n✽ Cerebrating… (39s · ↓ 3.1k tokens)\n───\n❯ \n") == "Cerebrating… 39s")
        precondition(claudeActivity("✻ Baking… (1m 20s · esc to interrupt)") == "Baking… 1m 20s")
        precondition(claudeActivity("⏺ All done, the build passes.\n❯ ") == nil)

        // whatever you type in Reply must reach the terminal byte for byte, quotes and all
        for text in ["plain", #"say "hi" \ there"#, "\u{1b}[B", "yes\r", "", #"" & do shell script "x" & ""#] {
            var err: NSDictionary?
            let back = NSAppleScript(source: "return \(appleScriptString(text))")?.executeAndReturnError(&err).stringValue
            precondition(back == text, "round trip failed for \(text.debugDescription): \(String(describing: back)) \(String(describing: err))")
        }

        print("all checks passed")
    }
}
