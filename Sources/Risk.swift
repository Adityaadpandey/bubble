import Foundation

// Plain-words warnings for a command or path someone is about to approve, e.g.
//   riskNotes("$ rm -rf build && sudo make install") == ["Deletes files for good", "Runs with admin rights"]
// A hint, not a verdict: it only knows the usual footguns, so no warning doesn't mean it's safe.
private let riskRules: [(pattern: String, note: String, ignoreCase: Bool)] = [
    (#"\brm\s+(-[a-zA-Z]*[rf]|--recursive|--force)"#, "Deletes files for good", false),
    (#"\bsudo\b"#, "Runs with admin rights", false),
    (#"\b(curl|wget)\b[^|;&]*\|\s*(sudo\s+)?(ba|z|da)?sh\b"#, "Runs a script it just downloaded", false),
    (#"\bgit\s+push\b.*(\s--force\b|\s-f\b|--force-with-lease)"#, "Overwrites history on the remote", false),
    (#"\bgit\s+(reset\s+--hard|clean\s+-[a-zA-Z]*f|checkout\s+--\s)"#, "Throws away uncommitted changes", false),
    (#"\b(chmod|chown)\s+-[a-zA-Z]*R"#, "Changes permissions on a whole folder", false),
    (#"\bdd\b.*\bof=|\bmkfs\b|\bdiskutil\s+(erase|partition)"#, "Writes straight to a disk", false),
    (#"\b(drop\s+(table|database|schema)|truncate\s+table)\b"#, "Deletes database data", true),
    (#"(~|\$HOME)/\.(ssh|aws|gnupg)\b|/\.(ssh|aws|gnupg)/|(^|/)\.env\b|(^|\s)/etc/|\bid_(rsa|ed25519)\b"#, "Touches secrets or system files", false),
    (#":\(\)\s*\{"#, "Looks like a fork bomb", false),
]

func riskNotes(_ text: String) -> [String] {
    riskRules.compactMap { rule in
        text.range(of: rule.pattern, options: rule.ignoreCase ? [.regularExpression, .caseInsensitive] : .regularExpression) == nil
            ? nil : rule.note
    }
}
