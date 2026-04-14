import XCTest
@testable import VoxboardShared

final class SmartFolderTests: XCTestCase {

    // MARK: - Codable round-trip

    func test_smartFolder_codableRoundTrip_preservesAllFields() throws {
        let id = UUID()
        let original = SmartFolder(
            id: id,
            name: "App Development",
            folderDescription: "Notes and ideas about iOS apps",
            bookmarkData: Data([0x01, 0x02, 0x03])
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SmartFolder.self, from: data)

        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.name, "App Development")
        XCTAssertEqual(decoded.folderDescription, "Notes and ideas about iOS apps")
        XCTAssertEqual(decoded.bookmarkData, Data([0x01, 0x02, 0x03]))
    }

    func test_smartFolder_codableRoundTrip_arrayPreservesOrder() throws {
        let folders = [
            SmartFolder(name: "First", folderDescription: "desc A", bookmarkData: Data([0x01])),
            SmartFolder(name: "Second", folderDescription: "desc B", bookmarkData: Data([0x02])),
            SmartFolder(name: "Third", folderDescription: "desc C", bookmarkData: Data([0x03])),
        ]

        let data = try JSONEncoder().encode(folders)
        let decoded = try JSONDecoder().decode([SmartFolder].self, from: data)

        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(decoded[0].name, "First")
        XCTAssertEqual(decoded[1].name, "Second")
        XCTAssertEqual(decoded[2].name, "Third")
    }

    // MARK: - resolveURL

    func test_resolveURL_returnsNil_forInvalidBookmarkData() {
        let folder = SmartFolder(
            name: "Broken",
            folderDescription: "Has invalid bookmark",
            bookmarkData: Data([0xFF, 0xFE])
        )
        XCTAssertNil(folder.resolveURL())
    }

    // MARK: - Identifiable

    func test_smartFolder_hasUniqueIDByDefault() {
        let a = SmartFolder(name: "A", folderDescription: "desc", bookmarkData: Data())
        let b = SmartFolder(name: "B", folderDescription: "desc", bookmarkData: Data())
        XCTAssertNotEqual(a.id, b.id)
    }

    // MARK: - AppConstants integration (uses in-memory UserDefaults)

    func test_saveAndLoadSmartFolders_roundTrips() {
        // Use an isolated UserDefaults suite so tests don't pollute App Group defaults.
        let suiteName = "VoxboardSmartFolderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let folders = [
            SmartFolder(name: "Work", folderDescription: "Professional notes", bookmarkData: Data([0xAA])),
            SmartFolder(name: "Personal", folderDescription: "Personal diary entries", bookmarkData: Data([0xBB])),
        ]

        // Save via JSON directly (mirrors AppConstants.saveSmartFolders logic)
        let encoded = try! JSONEncoder().encode(folders)
        defaults.set(encoded, forKey: AppConstants.smartFoldersKey)

        // Load back
        let rawData = defaults.data(forKey: AppConstants.smartFoldersKey)!
        let loaded = try! JSONDecoder().decode([SmartFolder].self, from: rawData)

        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].name, "Work")
        XCTAssertEqual(loaded[1].name, "Personal")
        XCTAssertEqual(loaded[0].bookmarkData, Data([0xAA]))
    }

    func test_smartFoldersKey_isDefined() {
        XCTAssertFalse(AppConstants.smartFoldersKey.isEmpty)
    }

    func test_smartFoldersEnabledKey_isDefined() {
        XCTAssertFalse(AppConstants.smartFoldersEnabledKey.isEmpty)
    }
}
