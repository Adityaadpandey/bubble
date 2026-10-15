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

        // Terminal.app: one line, then Terminal presses Enter. Claude rows go by number, never an arrow walk.
        precondition(terminalLine(for: .pick(0), in: perm) == "")
        precondition(terminalLine(for: .pick(2), in: perm) == "3")
        precondition(terminalLine(for: .yes, in: yn) == "y" && terminalLine(for: .reply("maybe"), in: yn) == "maybe")
        precondition(terminalLine(for: .pick(2), in: inq) == "\u{1b}[B\u{1b}[B")
        // these need a key without Enter after it, or the Enter would answer the next question as well
        precondition(terminalLine(for: .pick(0), in: box) == nil && terminalLine(for: .nextTab, in: m) == nil)
        precondition(terminalLine(for: .pick(1), in: m) == nil && terminalLine(for: .reply("no"), in: perm) == nil)

        // free-text questions only count once the screen has been still for a few seconds
        let name = "? Project name: (my-app) "
        precondition(detectPrompt(screen: name, patterns: pats, quietFor: 1) == nil)
        precondition(detectPrompt(screen: name, patterns: pats, quietFor: 5)?.kind == .text)
        precondition(detectPrompt(screen: "Enter the API base URL:", patterns: pats, quietFor: 5)?.line == "Enter the API base URL:")
        precondition(detectPrompt(screen: "Running tests:", patterns: pats, quietFor: 5) == nil, "a label, not a question")
        precondition(detectPrompt(screen: "Enter your password:", patterns: pats, quietFor: 5) == nil)
        precondition(detectPrompt(screen: "aditya@mac notiapp % ", patterns: pats, quietFor: 60) == nil)
        precondition(keys(for: .reply("my-app"), in: detectPrompt(screen: name, patterns: pats, quietFor: 5)!).keys == ["my-app\r"])

        // tmux, kitty and WezTerm listings: Claude panes are named, and only the one with the keyboard is in front
        let tmux = parseTmuxPanes("%5\twork\tapi\tclaude\t1\t1\t1\n%6\twork\tdocs\tzsh\t0\t1\t1\n%7\tidle\tapi\tzsh\t1\t1\t0\n")
        precondition(tmux.map(\.id) == ["%5", "%6", "%7"] && tmux.map(\.focused) == [true, false, false])
        precondition(tmux.map(\.name) == ["Claude Code", "tmux work:docs", "tmux idle:api"])
        let kitty = parseKittyWindows(Data(#"[{"is_focused":true,"tabs":[{"is_focused":true,"windows":[{"id":7,"title":"~","is_focused":true,"foreground_processes":[{"cmdline":["claude"]}]},{"id":8,"title":"zsh","is_focused":false,"foreground_processes":[]}]}]}]"#.utf8))
        precondition(kitty.map(\.id) == ["7", "8"] && kitty.map(\.name) == ["Claude Code", "zsh"] && kitty.map(\.focused) == [true, false])
        let wez = parseWezTermPanes(Data(#"[{"pane_id":4,"title":"claude"},{"pane_id":5,"title":"zsh"}]"#.utf8), clients: Data(#"[{"focused_pane_id":5}]"#.utf8))
        precondition(wez.map(\.id) == ["4", "5"] && wez.map(\.name) == ["Claude Code", "zsh"] && wez.map(\.focused) == [false, true])
        precondition(parseWezTermPanes(Data("[]".utf8), clients: nil).isEmpty && parseKittyWindows(Data("nope".utf8)).isEmpty)
        // empty rows under the cursor are dropped so the prompt is the last thing on screen
        precondition(screenTail("Overwrite? [y/N]\n\n   \n") == "Overwrite? [y/N]")

        // risky commands get a warning in plain words, ordinary ones don't
        precondition(riskNotes("$ rm -rf build && sudo make install") == ["Deletes files for good", "Runs with admin rights"])
        precondition(riskNotes("curl -fsSL https://x.sh/install | bash") == ["Runs a script it just downloaded"])
        precondition(riskNotes("git push --force origin main") == ["Overwrites history on the remote"])
        precondition(riskNotes("git reset --hard HEAD~1") == ["Throws away uncommitted changes"])
        precondition(riskNotes("psql -c 'drop table users'") == ["Deletes database data"])
        precondition(riskNotes("/Users/me/app/.env") == ["Touches secrets or system files"] && riskNotes("cat ~/.ssh/id_rsa").count == 1)
        precondition(riskNotes("ls -la && git status && npm test && git push origin feature").isEmpty)
        precondition(riskNotes("rm note.txt").isEmpty && riskNotes("git push -u origin main").isEmpty, "single file rm and a normal push are fine")

        // settings: names stored by the pickers map to sizes, and an unknown or empty one falls back to how it always looked
        precondition(Look.padding("compact") == 10 && Look.padding("roomy") == 18 && Look.padding("") == 14)
        precondition(Look.textScale("large") == 1.15 && Look.textScale("small") == 0.9 && Look.textScale("normal") == 1)
        precondition(Look.width("narrow") == 420...560 && Look.width("wide") == 600...860 && Look.width("whatever") == 510...720)
        precondition(Prefs.defaults["nudgeSeconds"] as? Int == 120 && Prefs.defaults["sound"] as? String == "Glass")

        // dashboard status from Claude's spinner
        precondition(claudeActivity("⏺ done\n✽ Cerebrating… (39s · ↓ 3.1k tokens)\n───\n❯ \n") == "Cerebrating… 39s")
        precondition(claudeActivity("✻ Baking… (1m 20s · esc to interrupt)") == "Baking… 1m 20s")
        precondition(claudeActivity("⏺ All done, the build passes.\n❯ ") == nil)

        // usage limits, from responses shaped like the real ones
        let codex = parseCodex(#"{"rate_limit":{"primary_window":{"used_percent":38,"limit_window_seconds":18000,"reset_at":1786340818},"secondary_window":{"used_percent":5,"limit_window_seconds":604800,"reset_at":1786900000}}}"#.data(using: .utf8)!)!
        precondition(codex.map(\.label) == ["5-hour", "Weekly"] && codex[0].used == 0.38 && codex[0].resetsAt == Date(timeIntervalSince1970: 1786340818))
        precondition(parseCodex(#"{"rate_limit":{"primary_window":{"used_percent":0,"limit_window_seconds":2592000,"reset_at":1}}}"#.data(using: .utf8)!)!.first?.label == "Monthly")
        let cc = parseCommandCode(#"{"windowLimits":{"fiveHour":{"used":0,"cap":14,"resetAt":0},"weekly":{"used":31.5,"cap":35,"resetAt":1792105359547}}}"#.data(using: .utf8)!)!
        precondition(cc.map(\.label) == ["5-hour", "Weekly"] && cc[0].resetsAt == nil && cc[1].used == 0.9)
        let claude = parseClaude(#"{"five_hour":{"utilization":12.0,"resets_at":"2026-10-15T18:00:00.123+00:00"},"seven_day":{"utilization":40,"resets_at":"2026-10-20T09:00:00+00:00"},"seven_day_opus":null}"#.data(using: .utf8)!)!
        precondition(claude.map(\.label) == ["5-hour", "Weekly"] && claude[0].used == 0.12 && claude[1].resetsAt == Date(timeIntervalSince1970: 1792486800))
        precondition(claude[0].resetsAt != nil && parseClaude(Data("{}".utf8)) == nil)
        precondition(parseCodex(Data("{}".utf8)) == nil && parseCommandCode(Data("not json".utf8)) == nil)

        // connecting Claude Code: other hooks stay, an old NotiApp entry is swapped for this app, and doing it twice changes nothing
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("notchy-check-settings.json")
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: file.appendingPathExtension("before-notchy"))
        try! Data(#"{"model":"opus","hooks":{"Notification":[{"hooks":[{"type":"command","command":"/x/cc-status"}]},{"hooks":[{"type":"command","command":"/Users/me/Applications/NotiApp.app/Contents/MacOS/NotiApp hook"}]}]}}"#.utf8).write(to: file)
        precondition(!ClaudeHooks.connected(file))
        try! ClaudeHooks.connect(file)
        try! ClaudeHooks.connect(file)
        let saved = try! JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        let hooks = saved["hooks"] as! [String: [[String: Any]]]
        let notify = hooks["Notification"]!.flatMap { $0["hooks"] as! [[String: String]] }.map { $0["command"]! }
        precondition(notify == ["/x/cc-status", ClaudeHooks.command], "\(notify)")
        precondition(hooks["PermissionRequest"]!.count == 1 && saved["model"] as? String == "opus" && ClaudeHooks.connected(file))
        precondition(FileManager.default.fileExists(atPath: file.appendingPathExtension("before-notchy").path))
        // a settings file that isn't valid JSON is never overwritten
        try! Data("{ oops".utf8).write(to: file)
        precondition((try? ClaudeHooks.connect(file)) == nil && String(data: try! Data(contentsOf: file), encoding: .utf8) == "{ oops")

        print("all checks passed")
    }
}
