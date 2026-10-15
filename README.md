# Perch

Perch lives in your MacBook's notch and taps you on the shoulder when something in your terminal is waiting on you.

When Claude Code asks "Do you want to proceed?", or any CLI stops at `[y/N]`, a pick-one list or a question, the notch opens up into a card with the question and its choices. Click an answer (or type a reply) and Perch types it into the right iTerm2 tab for you. You never have to go find the tab.

Hover over the notch, or click it, to see what's waiting, what's still running, and how much of your Claude, Codex and Command Code plan limits you've used.

## What you need

- A Mac on macOS 14 Sonoma or later (Apple silicon or Intel). A notch is nice but not required: without one, Perch opens from the top middle of the screen.
- [iTerm2](https://iterm2.com). Perch reads and answers prompts in iTerm2 tabs only.
- Claude Code, Codex and Command Code are all optional. Perch shows usage for whichever of them you're signed in to.

## Installing

Paste this into Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/Adityaadpandey/notchy/main/install.sh | bash
```

That's it. It downloads the latest Perch, puts it in Applications and opens it. Run the same line again any time to update.

**Rather click than type?** Download `Perch.dmg` from the [latest release](https://github.com/Adityaadpandey/notchy/releases/latest), open it and drag **Perch** onto **Applications**. Perch isn't notarized by Apple yet, so the first time you open it macOS says it can't check it: go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway**. (The Terminal line above skips this step.)

### The first minute

1. When macOS asks if Perch may control iTerm2, click **Allow**. That's how it reads prompts and types your answers.
2. If you use Claude Code, hover over the notch and click **Connect Claude Code**. This adds two small hooks to `~/.claude/settings.json`, so cards show the exact command or diff you're approving, and Perch pings you when Claude finishes. Your other hooks are left alone, and the file is backed up first as `settings.json.before-perch`.
3. The first time Perch shows your Claude usage, macOS asks if it may read Claude Code's login from your Keychain. Click **Always Allow**, or **Deny** if you'd rather not see Claude usage.

Perch starts at login. You can turn that off in the **⋯** menu.

## Using it

- **A card drops out of the notch** when a prompt is waiting in a tab you're not looking at. Click a choice, or type in the reply box and press Return. The card folds away as soon as you answer.
- **Keyboard:** press **⌃⌥Space** to put the keyboard on the top card (press it again for the next card). Then:
  - **1–9** picks a choice, **Y** / **N** answers a yes/no question
  - **← →** move between questions
  - **Tab** jumps to the reply box, **Esc** hands the keyboard back
- **Hover over the notch** (or click it, or the bell in the menu bar) for the dashboard: tabs waiting on you, tabs still working, and your plan limits.
- **Pause** in the dashboard silences Perch for an hour, or until you resume it.
- **Teach it a new CLI:** **⋯ → Edit prompt patterns…** opens `~/.config/perch/patterns.txt`, one regex per line, matched against the last line of each tab.

## Privacy

Everything stays on your Mac. Perch reads your iTerm2 tabs locally to spot prompts and never sends them anywhere.

For plan limits it uses the logins those tools already saved on your Mac: Claude Code's login from the Keychain, `~/.codex/auth.json` and `~/.commandcode/auth.json`. It sends each one only to that tool's own server (api.anthropic.com, chatgpt.com, api.commandcode.ai), the same request the tool itself makes for its usage screen. Perch never refreshes or changes these logins.

## Building from source

You need the Xcode command line tools (`xcode-select --install`).

```sh
make install   # builds Perch.app and puts it in ~/Applications
make check     # runs the tests
make dist      # builds build/Perch.zip to share
make dmg       # builds build/Perch.dmg, the drag-to-Applications installer
make icon      # redraws the app icon from Tools/icon.swift
```

To publish a new version, bump `CFBundleShortVersionString` in `Info.plist` and run `make release`. It uploads the zip and the disk image to a GitHub release, and the install line picks it up straight away.

## Uninstalling

Quit Perch from the **⋯** menu and delete it from Applications. If you connected Claude Code, remove the two entries ending in `Perch hook` from `~/.claude/settings.json`, or put back `settings.json.before-perch`. Perch's own files are `~/.config/perch` and `~/Library/Logs/Perch.log`.
