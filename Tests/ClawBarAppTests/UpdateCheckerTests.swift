import XCTest
@testable import ClawBarApp

final class UpdateCheckerTests: XCTestCase {
    func testExpectedSHA256ParsesChecksumLine() {
        let checksum = "95f6f74f5bbf83ad5f1f2e84aebf4de90f4f81d9b89abc7fca8c5f3d7a2fef11  ClawBar.dmg\n"
        XCTAssertEqual(
            UpdateChecker.expectedSHA256(from: checksum),
            "95f6f74f5bbf83ad5f1f2e84aebf4de90f4f81d9b89abc7fca8c5f3d7a2fef11"
        )
    }

    func testValidateBinaryDownloadResponseAcceptsDMGMimeType() throws {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com/ClawBar.dmg")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/x-apple-diskimage"]
        )!
        let data = Data([0x00, 0x01])

        XCTAssertNoThrow(try UpdateChecker.validateBinaryDownloadResponse(response, data: data, expectedKind: .dmg))
    }

    func testValidateBinaryDownloadResponseRejectsUnexpectedMimeTypeForDMG() {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com/ClawBar.dmg")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!

        XCTAssertThrowsError(
            try UpdateChecker.validateBinaryDownloadResponse(response, data: Data("oops".utf8), expectedKind: .dmg)
        )
    }

    func testUpdateInfoSelectsDMGAndChecksumAssetsForNewerRelease() throws {
        let data = Data(
            """
            {
              "tag_name": "v0.2.0",
              "html_url": "https://github.com/edstace/claw-bar/releases/tag/v0.2.0",
              "draft": false,
              "prerelease": false,
              "body": "Bug fixes and polish.",
              "assets": [
                {
                  "name": "ClawBar.dmg",
                  "browser_download_url": "https://github.com/edstace/claw-bar/releases/download/v0.2.0/ClawBar.dmg"
                },
                {
                  "name": "ClawBar.dmg.sha256",
                  "browser_download_url": "https://github.com/edstace/claw-bar/releases/download/v0.2.0/ClawBar.dmg.sha256"
                }
              ]
            }
            """.utf8
        )

        let info = try UpdateChecker.updateInfo(fromReleaseData: data, currentVersion: "0.1.21")
        XCTAssertEqual(info?.version, "0.2.0")
        XCTAssertEqual(info?.downloadURL.absoluteString, "https://github.com/edstace/claw-bar/releases/download/v0.2.0/ClawBar.dmg")
        XCTAssertEqual(info?.checksumURL?.absoluteString, "https://github.com/edstace/claw-bar/releases/download/v0.2.0/ClawBar.dmg.sha256")
        XCTAssertEqual(info?.releaseNotes, "Bug fixes and polish.")
    }

    func testUpdateInfoReturnsNilForDraftAndPrerelease() throws {
        let draft = Data(
            """
            {
              "tag_name": "v0.2.0",
              "html_url": "https://github.com/edstace/claw-bar/releases/tag/v0.2.0",
              "draft": true,
              "prerelease": false,
              "body": "",
              "assets": []
            }
            """.utf8
        )
        let prerelease = Data(
            """
            {
              "tag_name": "v0.2.0-beta.1",
              "html_url": "https://github.com/edstace/claw-bar/releases/tag/v0.2.0-beta.1",
              "draft": false,
              "prerelease": true,
              "body": "",
              "assets": []
            }
            """.utf8
        )

        XCTAssertNil(try UpdateChecker.updateInfo(fromReleaseData: draft, currentVersion: "0.1.21"))
        XCTAssertNil(try UpdateChecker.updateInfo(fromReleaseData: prerelease, currentVersion: "0.1.21"))
    }

    func testUpdateInfoReturnsNilForNonNewerVersion() throws {
        let sameVersion = Data(
            """
            {
              "tag_name": "v0.1.21",
              "html_url": "https://github.com/edstace/claw-bar/releases/tag/v0.1.21",
              "draft": false,
              "prerelease": false,
              "body": "",
              "assets": []
            }
            """.utf8
        )

        XCTAssertNil(try UpdateChecker.updateInfo(fromReleaseData: sameVersion, currentVersion: "0.1.21"))
    }
}
