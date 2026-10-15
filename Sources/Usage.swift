import Foundation

// One window of a plan's limit, e.g. "5h" at 38% that resets at 4:10 pm
struct Limit: Equatable {
    let label: String
    let used: Double // 0...1
    let resetsAt: Date?
}

struct Usage: Identifiable, Equatable {
    let id: String // "Codex", "Command Code"
    var limits: [Limit] = []
    var error: String?
}

// "5h", "Week", "Month" from a window length, so every tool reads the same way
func windowLabel(seconds: Double) -> String {
    switch seconds {
    case ..<(86400 - 1): return "\(Int((seconds / 3600).rounded()))h"
    case ..<(8 * 86400): return "Week"
    default: return "Month"
    }
}

// Codex, from chatgpt.com/backend-api/wham/usage:
//   {"rate_limit": {"primary_window": {"used_percent": 38, "limit_window_seconds": 18000, "reset_at": 1786340818}, "secondary_window": null}}
func parseCodex(_ data: Data) -> [Limit]? {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rate = obj["rate_limit"] as? [String: Any] else { return nil }
    return ["primary_window", "secondary_window"].compactMap { key in
        guard let w = rate[key] as? [String: Any], let pct = (w["used_percent"] as? NSNumber)?.doubleValue else { return nil }
        let reset = (w["reset_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return Limit(label: windowLabel(seconds: (w["limit_window_seconds"] as? NSNumber)?.doubleValue ?? 0), used: pct / 100, resetsAt: reset)
    }
}

// Command Code, from api.commandcode.ai/alpha/billing/credits (resetAt is in milliseconds, 0 means the window hasn't started):
//   {"windowLimits": {"fiveHour": {"used": 0, "cap": 14, "resetAt": 0}, "weekly": {"used": 31.2, "cap": 35, "resetAt": 1792105359547}}}
func parseCommandCode(_ data: Data) -> [Limit]? {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let windows = obj["windowLimits"] as? [String: Any] else { return nil }
    return [("fiveHour", "5h"), ("weekly", "Week")].compactMap { key, label in
        guard let w = windows[key] as? [String: Any],
              let used = (w["used"] as? NSNumber)?.doubleValue, let cap = (w["cap"] as? NSNumber)?.doubleValue, cap > 0 else { return nil }
        let ms = (w["resetAt"] as? NSNumber)?.doubleValue ?? 0
        return Limit(label: label, used: min(used / cap, 1), resetsAt: ms > 0 ? Date(timeIntervalSince1970: ms / 1000) : nil)
    }
}

// Asks each tool's own server how much of your plan is left, using the login that tool already saved on this Mac.
// A tool that isn't installed (no login file) is simply left out.
enum UsageFetcher {
    private static let home = FileManager.default.homeDirectoryForCurrentUser

    static func fetchAll(_ done: @escaping ([Usage]) -> Void) {
        let group = DispatchGroup()
        var results: [String: Usage] = [:]
        let lock = NSLock()
        func add(_ u: Usage) { lock.lock(); results[u.id] = u; lock.unlock(); group.leave() }

        if let auth = json("~/.codex/auth.json"), let tokens = auth["tokens"] as? [String: Any],
           let token = tokens["access_token"] as? String {
            group.enter()
            var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let account = tokens["account_id"] as? String { req.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id") }
            get(req, name: "Codex", signIn: "Open Codex to sign in again", parse: parseCodex, add)
        }
        if let auth = json("~/.commandcode/auth.json"), let key = auth["apiKey"] as? String {
            group.enter()
            var req = URLRequest(url: URL(string: "https://api.commandcode.ai/alpha/billing/credits")!)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            get(req, name: "Command Code", signIn: "Run commandcode login", parse: parseCommandCode, add)
        }
        group.notify(queue: .main) { done(results.values.sorted { $0.id < $1.id }) }
    }

    private static func get(_ req: URLRequest, name: String, signIn: String, parse: @escaping (Data) -> [Limit]?, _ add: @escaping (Usage) -> Void) {
        var req = req
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 { return add(Usage(id: name, error: signIn)) }
            guard status == 200, let data, let limits = parse(data) else { return add(Usage(id: name, error: "Couldn't load usage")) }
            add(Usage(id: name, limits: limits))
        }.resume()
    }

    private static func json(_ path: String) -> [String: Any]? {
        let url = home.appendingPathComponent(String(path.dropFirst(2)))
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
