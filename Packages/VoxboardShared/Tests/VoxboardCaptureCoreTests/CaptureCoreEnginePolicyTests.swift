@_spi(Testing) import VoxboardCaptureCore
import Foundation
import XCTest

final class CaptureCoreEnginePolicyTests: XCTestCase {
    func test_shadowComparesOneFrozenInputBeforeSideEffectsAndLegacyRemainsAuthoritative() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = newNoteDestination()
        let noteURL = root.appendingPathComponent("Inbox/note.md")
        let request = CaptureRequest(
            id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            source: .app,
            destinationID: destination.id,
            payloads: [.text("synthetic text")],
            frontmatter: ["source": "synthetic"]
        )
        let accounting = EngineRecordingAccounting()
        let probe = EngineComparisonProbe(
            accounting: accounting,
            observedNoteURL: noteURL,
            comparison: CaptureCoreComparison(
                readinessMatched: true,
                logicalPathMatched: false,
                bytesMatched: false,
                resultHashMatched: false
            )
        )
        let pipeline = CapturePipeline(
            deliveryAccounting: accounting,
            enginePolicy: .shadow(using: probe)
        )

        let receipt = try await pipeline.capture(
            request,
            destination: destination,
            rootURL: root
        )

        XCTAssertEqual(receipt.noteURL, noteURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: noteURL.path))
        let events = await accounting.events
        XCTAssertEqual(events, ["reserve", "commit"])
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.comparisonCount, 1)
        XCTAssertTrue(snapshot.noSideEffectsAtComparison)
        XCTAssertEqual(snapshot.input?.requestID, request.id)
        XCTAssertEqual(snapshot.input?.logicalFolder, ["Inbox"])
        XCTAssertEqual(snapshot.input?.noteNameTemplate, "note.md")
        XCTAssertEqual(snapshot.input?.orderedFrontmatter, [
            CaptureCoreFrontmatterFieldDTO(name: "source", value: "synthetic")
        ])
        guard case .text(let text) = snapshot.input?.payloads.first else {
            return XCTFail("Expected admitted text payload")
        }
        XCTAssertEqual(text, "synthetic text")
    }

    func test_shadowAdmissionFailureDoesNotInvokeComparatorOrAlterLegacyOutcome() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = CaptureDestination(
            name: "Existing",
            rootBookmark: Data([1]),
            rootName: "Vault",
            noteTarget: .existingNote(relativePath: "Inbox.md")
        )
        let request = CaptureRequest(
            source: .app,
            destinationID: destination.id,
            payloads: [.text("legacy")]
        )
        let accounting = EngineRecordingAccounting()
        let probe = EngineComparisonProbe(
            accounting: accounting,
            observedNoteURL: root.appendingPathComponent("Inbox.md"),
            comparison: exactComparison
        )

        _ = try await CapturePipeline(
            deliveryAccounting: accounting,
            enginePolicy: .shadow(using: probe)
        ).capture(request, destination: destination, rootURL: root)

        let snapshot = await probe.snapshot()
        let events = await accounting.events
        XCTAssertEqual(snapshot.comparisonCount, 0)
        XCTAssertEqual(events, ["reserve", "commit"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Inbox.md").path))
    }

    func test_testOnlyRustFailsClosedOnUnsupportedAdmissionBeforeSideEffects() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = CaptureDestination(
            name: "Existing",
            rootBookmark: Data([1]),
            rootName: "Vault",
            noteTarget: .existingNote(relativePath: "Inbox.md")
        )
        let request = CaptureRequest(
            source: .app,
            destinationID: destination.id,
            payloads: [.text("must not write")]
        )
        let accounting = EngineRecordingAccounting()
        let probe = EngineComparisonProbe(
            accounting: accounting,
            observedNoteURL: root.appendingPathComponent("Inbox.md"),
            comparison: exactComparison
        )
        let pipeline = CapturePipeline(
            deliveryAccounting: accounting,
            enginePolicy: .rust(using: probe)
        )

        do {
            _ = try await pipeline.capture(request, destination: destination, rootURL: root)
            XCTFail("Expected Rust admission to fail closed")
        } catch let error as CaptureCoreAdmissionError {
            XCTAssertEqual(error, .unsupportedNoteTarget)
        }

        let snapshot = await probe.snapshot()
        let events = await accounting.events
        XCTAssertEqual(snapshot.comparisonCount, 0)
        XCTAssertEqual(events, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Inbox.md").path))
    }

    func test_testOnlyRustStopsAtCommitBarrierWithoutLegacyFallback() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = newNoteDestination()
        let noteURL = root.appendingPathComponent("Inbox/note.md")
        let request = CaptureRequest(
            source: .shareExtension,
            destinationID: destination.id,
            payloads: [.url(URL(string: "https://example.invalid")!, title: "Example")]
        )
        let accounting = EngineRecordingAccounting()
        let probe = EngineComparisonProbe(
            accounting: accounting,
            observedNoteURL: noteURL,
            comparison: exactComparison
        )
        let pipeline = CapturePipeline(
            deliveryAccounting: accounting,
            enginePolicy: .rust(using: probe)
        )

        do {
            _ = try await pipeline.capture(request, destination: destination, rootURL: root)
            XCTFail("Expected the M2 Rust commit barrier")
        } catch let error as CaptureCoreEngineError {
            XCTAssertEqual(error, .rustCommitNotPromoted)
        }

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.comparisonCount, 1)
        XCTAssertTrue(snapshot.noSideEffectsAtComparison)
        XCTAssertEqual(snapshot.input?.captureSource, "share")
        let events = await accounting.events
        XCTAssertEqual(events, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: noteURL.path))
    }

    func test_admissionUsesPortableScalarAndPathBoundsAndRejectsHiddenPolicy() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let folder = Array(repeating: "folder", count: 31).joined(separator: "/")
        let destination = CaptureDestination(
            name: "M2 bounds",
            rootBookmark: Data([1]),
            rootName: "Vault",
            noteTarget: .newNote(pathTemplate: folder + "/note")
        )
        let request = CaptureRequest(
            source: .app,
            destinationID: destination.id,
            payloads: [.text(String(repeating: "é", count: 65_536))]
        )
        let admitted = try CaptureCoreAdmission.admit(
            request: request,
            destination: destination,
            calendar: calendar
        )
        XCTAssertEqual(admitted.payloads.count, 1)
        XCTAssertEqual(admitted.logicalFolder.count, 31)

        var hiddenPolicy = request
        hiddenPolicy.originDraftUpdatedAt = Date(timeIntervalSince1970: 1)
        XCTAssertThrowsError(try CaptureCoreAdmission.admit(
            request: hiddenPolicy,
            destination: destination,
            calendar: calendar
        )) { error in
            XCTAssertEqual(error as? CaptureCoreAdmissionError, .unsupportedRequestPolicy)
        }

        var tooDeep = destination
        tooDeep.noteTarget = .newNote(
            pathTemplate: Array(repeating: "folder", count: 32).joined(separator: "/") + "/note"
        )
        XCTAssertThrowsError(try CaptureCoreAdmission.admit(
            request: request,
            destination: tooDeep,
            calendar: calendar
        )) { error in
            XCTAssertEqual(error as? CaptureCoreAdmissionError, .contractBoundExceeded)
        }
    }

    private var exactComparison: CaptureCoreComparison {
        CaptureCoreComparison(
            readinessMatched: true,
            logicalPathMatched: true,
            bytesMatched: true,
            resultHashMatched: true
        )
    }

    private func newNoteDestination() -> CaptureDestination {
        CaptureDestination(
            name: "M2",
            rootBookmark: Data([1]),
            rootName: "Vault",
            noteTarget: .newNote(pathTemplate: "Inbox/note.md")
        )
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureCoreEnginePolicyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor EngineRecordingAccounting: CaptureDeliveryAccounting {
    private(set) var events: [String] = []

    func reserve(for request: CaptureRequest) async throws -> CaptureDeliveryReservation {
        events.append("reserve")
        return .reserved(requestID: request.id, token: UUID())
    }

    func commit(_ reservation: CaptureDeliveryReservation) async throws {
        events.append("commit")
    }

    func release(_ reservation: CaptureDeliveryReservation) async {
        events.append("release")
    }
}

private actor EngineComparisonProbe: CaptureCoreComparing {
    struct Snapshot: Sendable {
        let comparisonCount: Int
        let noSideEffectsAtComparison: Bool
        let input: CaptureCoreAdmittedInput?
    }

    private let accounting: EngineRecordingAccounting
    private let observedNoteURL: URL
    private let comparison: CaptureCoreComparison
    private var comparisonCount = 0
    private var noSideEffectsAtComparison = false
    private var input: CaptureCoreAdmittedInput?

    init(
        accounting: EngineRecordingAccounting,
        observedNoteURL: URL,
        comparison: CaptureCoreComparison
    ) {
        self.accounting = accounting
        self.observedNoteURL = observedNoteURL
        self.comparison = comparison
    }

    func compare(_ input: CaptureCoreAdmittedInput) async throws -> CaptureCoreComparison {
        comparisonCount += 1
        self.input = input
        noSideEffectsAtComparison = await accounting.events.isEmpty
            && !FileManager.default.fileExists(atPath: observedNoteURL.path)
        return comparison
    }

    func snapshot() -> Snapshot {
        Snapshot(
            comparisonCount: comparisonCount,
            noSideEffectsAtComparison: noSideEffectsAtComparison,
            input: input
        )
    }
}
