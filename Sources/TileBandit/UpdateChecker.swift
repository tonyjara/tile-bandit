import Foundation

/// "Is there a newer Tile Bandit?" — asked on demand, never on a timer.
///
/// Installation goes through the Homebrew cask, so this deliberately doesn't
/// download or replace anything: knowing a new version exists, and knowing the
/// one command that installs it, is the whole job. Sparkle would be a
/// dependency plus a signing key, and two updaters disagreeing about what is
/// installed is worse than having none.
///
/// Permission-free like the rest of the app — one HTTPS GET, no entitlement, no
/// background schedule, and nothing sent but the request itself.
enum UpdateChecker {
    /// Where a human should land: release notes and the zip.
    static let releasesPage = URL(string: "https://github.com/tonyjara/tile-bandit/releases/latest")!

    /// The same release the cask's `livecheck :github_latest` reads, asked directly.
    private static let latestAPI = URL(string: "https://api.github.com/repos/tonyjara/tile-bandit/releases/latest")!

    static let upgradeCommand = "brew upgrade --cask tile-bandit"

    /// Whether we're a real `.app`. The same question `LoginItem.isSupported`
    /// asks, for a related reason: only a bundle has a stamped
    /// CFBundleShortVersionString to compare, and only a bundle was installed
    /// by Homebrew — telling a `swift run` build to `brew upgrade` would be
    /// wrong advice about a checkout it can't see.
    static var isBundledApp: Bool { Bundle.main.bundleIdentifier != nil }

    enum Outcome {
        case upToDate(current: String)
        case available(latest: String, current: String)
        case failed(reason: String)
    }

    /// GitHub's release JSON, cut down to the one field that matters.
    private struct Release: Decodable {
        let tagName: String
    }

    static func check() async -> Outcome {
        let current = Banner.version
        var request = URLRequest(url: latestAPI, timeoutInterval: 15)
        // GitHub answers 403 to an API request that carries no User-Agent.
        request.setValue("TileBandit/\(current)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            // 404 until a release is published, 403 when GitHub is rate-limiting
            // an unauthenticated caller. Both are worth saying out loud: read as
            // "up to date", either one would quietly strand someone on an old
            // build forever.
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                return .failed(reason: "GitHub answered \(http.statusCode).")
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let tag = try decoder.decode(Release.self, from: data).tagName
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            return isNewer(latest, than: current)
                ? .available(latest: latest, current: current)
                : .upToDate(current: current)
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }

    /// Dotted-numeric comparison, component by component, so 1.10.0 beats 1.9.0
    /// where a string compare would have it the other way round. A non-numeric
    /// component reads as 0, which keeps a "1.2.0-beta" tag from being offered
    /// as newer than the 1.2.0 already installed.
    static func isNewer(_ latest: String, than current: String) -> Bool {
        let new = components(latest), have = components(current)
        for index in 0 ..< max(new.count, have.count) {
            let lhs = index < new.count ? new[index] : 0
            let rhs = index < have.count ? have[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        version.split(separator: ".").map { part in Int(part.prefix(while: \.isNumber)) ?? 0 }
    }
}
