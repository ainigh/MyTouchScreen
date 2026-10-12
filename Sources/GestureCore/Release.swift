import Foundation

// What the updater needs from GitHub, parsed here (Foundation only) so it's tested on Linux.

/// A version like "1.0.12" (a leading "v" is fine). Compared number by number: 1.0.12 > 1.0.9.
public struct Version: Comparable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let parsed = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parsed.isEmpty, !parsed.contains(where: { $0 == nil }) else { return nil }
        parts = parsed.compactMap { $0 }
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (a: Version, b: Version) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: Version, b: Version) -> Bool { !(a < b) && !(b < a) }
}

/// The parts of a GitHub release the updater uses (GET /repos/{owner}/{repo}/releases/latest).
public struct Release: Decodable, Equatable {
    public struct Asset: Decodable, Equatable {
        public let name: String
        public let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    public let tag: String
    /// The commit the release was built from (CI passes the full sha).
    public let target: String?
    public let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tag = "tag_name"
        case target = "target_commitish"
        case assets
    }

    public static func decode(_ data: Data) throws -> Release {
        try JSONDecoder().decode(Release.self, from: data)
    }

    public var version: Version? { Version(tag) }

    public func asset(named name: String) -> Asset? { assets.first { $0.name == name } }
}

/// The newest commit on a branch (GET /repos/{owner}/{repo}/commits/{branch}).
public struct Commit: Decodable, Equatable {
    public let sha: String
    public let message: String

    private struct Details: Decodable { let message: String }
    private enum CodingKeys: String, CodingKey { case sha, commit }

    public init(sha: String, message: String) {
        self.sha = sha
        self.message = message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sha = try c.decode(String.self, forKey: .sha)
        message = try c.decode(Details.self, forKey: .commit).message
    }

    public static func decode(_ data: Data) throws -> Commit {
        try JSONDecoder().decode(Commit.self, from: data)
    }

    public var short: String { String(sha.prefix(7)) }
    /// The first line of the message.
    public var title: String { message.components(separatedBy: "\n").first ?? message }
}

/// What an update check concluded.
public enum UpdatePlan: Equatable {
    case upToDate
    /// GitHub built this commit: download the release.
    case prebuilt(Commit, Release)
    /// No release for this commit (CI still running, or Actions off): build it on this Mac.
    case buildHere(Commit)

    /// Compares the branch's newest commit with the one this copy was built from. A copy with no
    /// recorded commit (built by hand with `make app`) updates to whatever the branch has.
    public static func decide(head: Commit, installedCommit: String?, latestRelease: Release?,
                              assetName: String) -> UpdatePlan {
        if let mine = installedCommit, !mine.isEmpty, mine != "unknown",
           head.sha.hasPrefix(mine) || mine.hasPrefix(head.sha) {
            return .upToDate
        }
        if let release = latestRelease, release.target == head.sha, release.asset(named: assetName) != nil {
            return .prebuilt(head, release)
        }
        return .buildHere(head)
    }
}

/// Parses `swift --version` output ("… Swift version 5.10 (swift-5.10-RELEASE) …").
public enum SwiftToolchain {
    /// The package's swift-tools-version.
    public static let required = Version("5.9")!

    public static func version(in output: String) -> Version? {
        guard let range = output.range(of: #"Swift version (\d+(\.\d+)*)"#, options: .regularExpression) else { return nil }
        let match = output[range].replacingOccurrences(of: "Swift version ", with: "")
        return Version(match)
    }

    public static func isNewEnough(_ output: String) -> Bool {
        guard let v = version(in: output) else { return false }
        return !(v < required)
    }
}
