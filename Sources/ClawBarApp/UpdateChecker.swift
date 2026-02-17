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
    private static let acceptedDMGContentTypes: Set<String> = [
        "application/x-apple-diskimage",
        "application/octet-stream",
    ]
    private static let acceptedChecksumContentTypes: Set<String> = [
        "text/plain",
        "application/octet-stream",
    ]

    enum DownloadKind {
        case dmg
        case checksum
    }

    static func check(currentVersion: String) async throws -> UpdateInfo? {
        var request = URLRequest(url: latestReleaseURL)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ClawBar/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClawBarError.networkError("Update check failed: invalid HTTP response.")
        }
        guard (200...299).contains(http.statusCode) else {
            throw ClawBarError.networkError(readableStatusMessage(statusCode: http.statusCode, body: data))
        }

        let release: GitHubRelease
        do {
            release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw ClawBarError.networkError("Update check failed: invalid release payload.")
        }
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

    static func validateBinaryDownloadResponse(_ response: URLResponse, data: Data, expectedKind: DownloadKind) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ClawBarError.networkError("Update download failed: invalid HTTP response.")
        }
        guard (200...299).contains(http.statusCode) else {
            throw ClawBarError.networkError(readableStatusMessage(statusCode: http.statusCode, body: data))
        }
        guard !data.isEmpty else {
            throw ClawBarError.networkError("Update download failed: empty response body.")
        }

        let acceptedContentTypes: Set<String> = switch expectedKind {
        case .dmg: acceptedDMGContentTypes
        case .checksum: acceptedChecksumContentTypes
        }
        guard let header = http.value(forHTTPHeaderField: "Content-Type"), !header.isEmpty else {
            return
        }

        let mimeType = header.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard acceptedContentTypes.contains(mimeType) else {
            throw ClawBarError.networkError("Update download failed: unexpected content type '\(mimeType)'.")
        }
    }

    private static func readableStatusMessage(statusCode: Int, body: Data) -> String {
        let apiMessage = (try? JSONDecoder().decode(GitHubAPIError.self, from: body))?.message
        let detailSuffix: String
        if let apiMessage, !apiMessage.isEmpty {
            detailSuffix = ": \(apiMessage)"
        } else {
            detailSuffix = "."
        }

        switch statusCode {
        case 401, 403:
            return "Update feed is not accessible (HTTP \(statusCode))\(detailSuffix)"
        case 404:
            return "Update feed not found (HTTP 404). The releases repo may be private."
        default:
            return "Update check failed (HTTP \(statusCode))\(detailSuffix)"
        }
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

private struct GitHubAPIError: Decodable {
    let message: String?
}
