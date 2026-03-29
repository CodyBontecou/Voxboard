import XCTest
@testable import VoxboardShared

final class ExportFileFormatTests: XCTestCase {

    func test_txtFormat_hasCorrectExtension() {
        XCTAssertEqual(ExportFileFormat.txt.fileExtension, "txt")
    }

    func test_mdFormat_hasCorrectExtension() {
        XCTAssertEqual(ExportFileFormat.md.fileExtension, "md")
    }

    func test_jsonFormat_hasCorrectExtension() {
        XCTAssertEqual(ExportFileFormat.json.fileExtension, "json")
    }

    func test_yamlFormat_hasCorrectExtension() {
        XCTAssertEqual(ExportFileFormat.yaml.fileExtension, "yaml")
    }

    func test_allFormats_areCaseIterable() {
        XCTAssertEqual(ExportFileFormat.allCases.count, 4)
    }

    func test_allModes_areCaseIterable() {
        XCTAssertEqual(ExportFileMode.allCases.count, 2)
    }

    func test_formats_areCodable() throws {
        let encoded = try JSONEncoder().encode(ExportFileFormat.md)
        let decoded = try JSONDecoder().decode(ExportFileFormat.self, from: encoded)
        XCTAssertEqual(decoded, .md)
    }

    func test_modes_areCodable() throws {
        let encoded = try JSONEncoder().encode(ExportFileMode.append)
        let decoded = try JSONDecoder().decode(ExportFileMode.self, from: encoded)
        XCTAssertEqual(decoded, .append)
    }

    func test_yamlProperties_haveDefaultSelectionForAllProperties() {
        XCTAssertEqual(ExportYAMLProperty.defaultSelection.count, ExportYAMLProperty.allCases.count)
    }
}
