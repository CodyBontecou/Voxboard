import XCTest
@testable import Voxboard

final class ReleaseNotesPresentationTests: XCTestCase {
    func testUnseenCurrentVersionWithNotesIsPresented() {
        XCTAssertTrue(VoxboardReleaseNotes.shouldPresentCurrentVersion(
            currentAppVersion: "2.0.3",
            latestSeenAppVersion: nil,
            releaseNotesEnabled: true
        ))
    }

    func testSeenCurrentVersionIsNotPresented() {
        XCTAssertFalse(VoxboardReleaseNotes.shouldPresentCurrentVersion(
            currentAppVersion: "2.0.3",
            latestSeenAppVersion: "2.0.3",
            releaseNotesEnabled: true
        ))
    }

    func testVersionWithoutNotesIsNotPresented() {
        XCTAssertFalse(VoxboardReleaseNotes.shouldPresentCurrentVersion(
            currentAppVersion: "9.9.9",
            latestSeenAppVersion: nil,
            releaseNotesEnabled: true
        ))
    }

    func testDisabledReleaseNotesAreNotPresented() {
        XCTAssertFalse(VoxboardReleaseNotes.shouldPresentCurrentVersion(
            currentAppVersion: "2.0.3",
            latestSeenAppVersion: nil,
            releaseNotesEnabled: false
        ))
    }
}
