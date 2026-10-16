import Foundation

// What you answered from the notch, newest first, kept in ~/.config/bubble/history.json so "why did that run?" has an answer.
// e.g. "14:02 · Claude Code · bubble · Bash · rm -rf build → Yes". Typed replies are never stored, only that one was sent.
struct HistoryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    let at: Date
    let tab, question, answer, command: String
}

/// What to call an answer in the history, or nil for ones that aren't a decision (ticking one box of several).
func answerLabel(_ a: Answer, in p: Prompt) -> String? {
    switch a {
    case .pick(let i): p.rows.indices.contains(i) && p.rows[i].checked == nil ? p.rows[i].label : nil
    case .yes: "Yes"
    case .no: "No"
    case .submit: "Submitted"
    case .reply: "Typed a reply"
    case .prevTab, .nextTab: nil
    }
}

final class History: ObservableObject {
    static let shared = History()
    static let limit = 200
    private let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/bubble/history.json")
    @Published private(set) var entries: [HistoryEntry] = []

    init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? Data(contentsOf: file)).flatMap { try? decoder.decode([HistoryEntry].self, from: $0) } ?? []
    }

    func add(_ entry: HistoryEntry) {
        entries = Array(([entry] + entries).prefix(Self.limit))
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(entries).write(to: file, options: .atomic)
    }
}
