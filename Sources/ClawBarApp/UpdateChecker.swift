import Foundation

struct UpdateInfo {
    let version: String
    let releasePageURL: URL
    let downloadURL: URL
    let checksumURL: URL?
    let releaseNotes: String
}

enum UpdateChecker {
    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/edstace/claw-bar/releases/latest")!

    static func check(currentVersion: String) async throws -> UpdateInfo? {
        var request = URLRequest(url: latestReleaseURL)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ClawBar/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ClawBarError.networkError("Update check failed.")
        }

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard !release.draft, !release.prerelease else { return nil }

        let latestVersion = normalizedVersion(fromTag: release.tagName)
        guard isNewer(latestVersion, than: currentVersion) else { return nil }

        let dmgAsset = release.assets.first { $0.name.lowercased().hasSuffix(".dmg") }
        let checksumAsset = release.assets.first { $0.name.lowercased().hasSuffix(".dmg.sha256") }
        let downloadURL = dmgAsset?.browserDownloadURL ?? release.htmlURL
        let notes = release.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return UpdateInfo(
            version: latestVersion,
            releasePageURL: release.htmlURL,
            downloadURL: downloadURL,
            checksumURL: checksumAsset?.browserDownloadURL,
            releaseNotes: notes
        )
    }

    private static func normalizedVersion(fromTag tag: String) -> String {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }

    private static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        let a = versionComponents(lhs)
        let b = versionComponents(rhs)
        let count = max(a.count, b.count)
        for i in 0..<count {
            let ai = i < a.count ? a[i] : 0
            let bi = i < b.count ? b[i] : 0
            if ai != bi { return ai > bi }
        }
        return false
    }

    private static func versionComponents(_ value: String) -> [Int] {
        let core = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? value
        return core.split(separator: ".").compactMap { Int($0) }
    }

    static func expectedSHA256(from checksumFile: String) -> String? {
        for line in checksumFile.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            if let first = parts.first, first.count == 64 {
                return String(first).lowercased()
            }
        }
        return nil
    }
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let htmlURL: URL
    let draft: Bool
    let prerelease: Bool
    let body: String?
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case draft
        case prerelease
        case body
        case assets
    }
}
