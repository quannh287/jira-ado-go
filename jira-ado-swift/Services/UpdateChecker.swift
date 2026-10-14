import Foundation

/// A newer release on GitHub: its version, Markdown notes, and where to get it.
struct AppUpdate: Identifiable, Equatable {
    var version: String
    var notes: String
    var download: URL  // the DMG, else the release page
    var page: URL
    var id: String { version }
}

/// Reads the latest published release of the app's public repository (no token: 60 checks an hour per address).
enum GitHubReleases {
    static let repo = "quannh287/jira-ado-go"

    static func latest(repo: String? = nil) async throws -> AppUpdate {
        let (resp, err) = await HTTPClient(base: "https://api.github.com", auth: "").send("GET", "/repos/\(repo ?? Self.repo)/releases/latest")
        if let err { throw err }
        guard let o = parseJSON(resp.body) as? JSONObject, let tag = o["tag_name"] as? String,
              let page = (o["html_url"] as? String).flatMap(URL.init(string:)) else {
            throw Failure("GitHub's latest release has no tag")
        }
        let dmg = (o["assets"] as? [JSONObject] ?? [])
            .first { ($0["name"] as? String ?? "").lowercased().hasSuffix(".dmg") }
            .flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init(string:)) }
        return AppUpdate(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, notes: o["body"] as? String ?? "",
                         download: dmg ?? page, page: page)
    }
}

/// Whether version a is newer than b, comparing numeric parts ("0.10.0" > "0.9.1"); a pre-release suffix counts as older.
func isNewer(_ a: String, than b: String) -> Bool {
    func parts(_ v: String) -> (nums: [Int], pre: Bool) {
        var v = v.trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("v") { v.removeFirst() }
        let core = v.split(separator: "-", maxSplits: 1)
        return (core.first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? [], core.count > 1)
    }
    let (x, y) = (parts(a), parts(b))
    for i in 0..<max(x.nums.count, y.nums.count) {
        let p = i < x.nums.count ? x.nums[i] : 0, q = i < y.nums.count ? y.nums[i] : 0
        if p != q { return p > q }
    }
    return !x.pre && y.pre  // 1.0.0 is newer than 1.0.0-beta
}
