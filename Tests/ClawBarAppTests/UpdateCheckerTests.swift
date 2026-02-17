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
}
