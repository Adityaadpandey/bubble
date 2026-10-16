import Foundation

/// Is `latest` a newer version than `current`? Compares the numbers, not the text, so "v1.10" is newer than "1.9".
func isNewer(_ latest: String, than current: String) -> Bool {
    let parts = { (v: String) in v.drop { $0 == "v" || $0 == "V" }.split(separator: ".").map { Int($0) ?? 0 } }
    let (a, b) = (parts(latest), parts(current))
    for i in 0..<max(a.count, b.count) {
        let (x, y) = (i < a.count ? a[i] : 0, i < b.count ? b[i] : 0)
        if x != y { return x > y }
    }
    return false
}

// Asks GitHub which release is the newest, e.g. {"tag_name": "v1.3", "html_url": "https://github.com/.../releases/tag/v1.3"}.
// Only ever called when you've turned "Check for updates" on in Settings, and it sends nothing about you.
enum UpdateCheck {
    static func newer(than current: String, _ done: @escaping ((version: String, page: URL)?) -> Void) {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/Adityaadpandey/bubble/releases/latest")!)
        req.timeoutInterval = 10
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            guard let tag = obj?["tag_name"] as? String, isNewer(tag, than: current),
                  let page = (obj?["html_url"] as? String).flatMap(URL.init) else { return DispatchQueue.main.async { done(nil) } }
            DispatchQueue.main.async { done((String(tag.drop { $0 == "v" }), page)) }
        }.resume()
    }
}
