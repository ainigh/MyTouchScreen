import XCTest
@testable import GestureCore

final class ReleaseTests: XCTestCase {
    func testVersionOrdering() {
        XCTAssertLessThan(Version("1.0.9")!, Version("v1.0.12")!)
        XCTAssertEqual(Version("1.0")!, Version("1.0.0")!)
        XCTAssertNil(Version("1.0-abc"))
        XCTAssertNil(Version(""))
    }

    let releaseJSON = #"""
    {"tag_name":"v1.0.7","target_commitish":"abcdef1234567890","html_url":"https://x",
     "assets":[{"name":"GesturePointer.zip","browser_download_url":"https://example.com/GesturePointer.zip"}]}
    """#
    let commitJSON = #"{"sha":"abcdef1234567890","commit":{"message":"Fix pinch\n\nDetails"}}"#

    func testDecodesGitHubPayloads() throws {
        let release = try Release.decode(Data(releaseJSON.utf8))
        XCTAssertEqual(release.version, Version("1.0.7"))
        XCTAssertNotNil(release.asset(named: "GesturePointer.zip"))
        let commit = try Commit.decode(Data(commitJSON.utf8))
        XCTAssertEqual(commit.short, "abcdef1")
        XCTAssertEqual(commit.title, "Fix pinch")
    }

    func testUpdatePlan() throws {
        let release = try Release.decode(Data(releaseJSON.utf8))
        let head = try Commit.decode(Data(commitJSON.utf8))
        XCTAssertEqual(UpdatePlan.decide(head: head, installedCommit: "abcdef1234567890", latestRelease: release,
                                         assetName: "GesturePointer.zip"), .upToDate)
        XCTAssertEqual(UpdatePlan.decide(head: head, installedCommit: "abcdef1", latestRelease: release,
                                         assetName: "GesturePointer.zip"), .upToDate)
        XCTAssertEqual(UpdatePlan.decide(head: head, installedCommit: "0000000", latestRelease: release,
                                         assetName: "GesturePointer.zip"), .prebuilt(head, release))
        let newer = Commit(sha: "ffff", message: "newer")
        XCTAssertEqual(UpdatePlan.decide(head: newer, installedCommit: "abcdef1", latestRelease: release,
                                         assetName: "GesturePointer.zip"), .buildHere(newer))
        XCTAssertEqual(UpdatePlan.decide(head: head, installedCommit: nil, latestRelease: nil,
                                         assetName: "GesturePointer.zip"), .buildHere(head))
    }

    func testSwiftVersionParsing() {
        let out = "swift-driver version: 1.90.11.1 Apple Swift version 5.10 (swiftlang-5.10.0.13 clang-1500.3.9.4)\nTarget: arm64-apple-macosx14.0"
        XCTAssertEqual(SwiftToolchain.version(in: out), Version("5.10"))
        XCTAssertTrue(SwiftToolchain.isNewEnough(out))
        XCTAssertFalse(SwiftToolchain.isNewEnough("Apple Swift version 5.8.1 (swiftlang-5.8.0.124.5)"))
        XCTAssertTrue(SwiftToolchain.isNewEnough("Swift version 6.0.3 (swift-6.0.3-RELEASE)"))
        XCTAssertFalse(SwiftToolchain.isNewEnough("command not found"))
    }
}
