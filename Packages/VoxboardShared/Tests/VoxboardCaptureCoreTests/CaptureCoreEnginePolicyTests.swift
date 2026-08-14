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

    func test_testOnlyRustRejectsAggregateControlBeforeComparatorOrSideEffects() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = newNoteDestination()
        let individuallyValid = String(repeating: "a", count: 65_536)
        let request = CaptureRequest(
            source: .app,
            destinationID: destination.id,
            payloads: [
                .text(individuallyValid),
                .text(individuallyValid),
                .text(individuallyValid),
            ]
        )
        let accounting = EngineRecordingAccounting()
        let noteURL = root.appendingPathComponent("Inbox/note.md")
        let probe = EngineComparisonProbe(
            accounting: accounting,
            observedNoteURL: noteURL,
            comparison: exactComparison
        )

        do {
            _ = try await CapturePipeline(
                deliveryAccounting: accounting,
                enginePolicy: .rust(using: probe)
            ).capture(request, destination: destination, rootURL: root)
            XCTFail("Expected aggregate control admission to fail")
        } catch let error as CaptureCoreAdmissionError {
            XCTAssertEqual(error, .aggregateControlBoundExceeded)
        }

        let snapshot = await probe.snapshot()
        let events = await accounting.events
        XCTAssertEqual(snapshot.comparisonCount, 0)
        XCTAssertEqual(events, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: noteURL.path))
    }

    func test_testOnlyRustRejectsAmbiguousFrontmatterCompositionBeforeSideEffects() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = newNoteDestination()
        let noteURL = root.appendingPathComponent("Inbox/note.md")
        let request = CaptureRequest(
            source: .app,
            destinationID: destination.id,
            payloads: [.text("---\nuser: owned\n---\nbody")]
        )
        let accounting = EngineRecordingAccounting()
        let probe = EngineComparisonProbe(
            accounting: accounting,
            observedNoteURL: noteURL,
            comparison: exactComparison
        )

        do {
            _ = try await CapturePipeline(
                deliveryAccounting: accounting,
                enginePolicy: .rust(using: probe)
            ).capture(request, destination: destination, rootURL: root)
            XCTFail("Expected ambiguous payload frontmatter to remain legacy-only")
        } catch let error as CaptureCoreAdmissionError {
            XCTAssertEqual(error, .unsupportedFrontmatterComposition)
        }

        let snapshot = await probe.snapshot()
        let events = await accounting.events
        XCTAssertEqual(snapshot.comparisonCount, 0)
        XCTAssertEqual(events, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: noteURL.path))

        var prefixed = destination
        prefixed.entryPrefix = "---\ntemplate: true\n---\n"
        var metadataRequest = CaptureRequest(
            source: .app,
            destinationID: destination.id,
            payloads: [.text("body")]
        )
        metadataRequest.frontmatter = ["request": "metadata"]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        XCTAssertThrowsError(try CaptureCoreAdmission.admit(
            request: metadataRequest,
            destination: prefixed,
            calendar: calendar
        )) { error in
            XCTAssertEqual(error as? CaptureCoreAdmissionError, .unsupportedFrontmatterComposition)
        }

        metadataRequest.frontmatter = [:]
        XCTAssertNoThrow(try CaptureCoreAdmission.admit(
            request: metadataRequest,
            destination: prefixed,
            calendar: calendar
        ))
    }

    func test_admissionRejectsBoundaryWhitespaceInEveryPathSegment() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let request = CaptureRequest(
            source: .app,
            destinationID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            payloads: [.text("payload")]
        )

        for template in ["Inbox/ note ", "Inbox/ note", " Inbox/note", "Inbox /note"] {
            var destination = newNoteDestination(id: request.destinationID)
            destination.noteTarget = .newNote(pathTemplate: template)
            XCTAssertThrowsError(try CaptureCoreAdmission.admit(
                request: request,
                destination: destination,
                calendar: calendar
            )) { error in
                XCTAssertEqual(error as? CaptureCoreAdmissionError, .unsupportedDestinationPolicy)
            }
        }
    }

    func test_admissionRejectsPathTokensThatDifferBetweenRenderers() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let request = CaptureRequest(
            source: .app,
            destinationID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            payloads: [.text("payload")]
        )

        var folderToken = newNoteDestination(id: request.destinationID)
        folderToken.noteTarget = .newNote(pathTemplate: "Archive/{date}/note")
        XCTAssertThrowsError(try CaptureCoreAdmission.admit(
            request: request,
            destination: folderToken,
            calendar: calendar
        )) { error in
            XCTAssertEqual(error as? CaptureCoreAdmissionError, .unsupportedLogicalFolderToken)
        }

        for template in ["Inbox/{period}", "Inbox/{source}"] {
            var noteToken = newNoteDestination(id: request.destinationID)
            noteToken.noteTarget = .newNote(pathTemplate: template)
            XCTAssertThrowsError(try CaptureCoreAdmission.admit(
                request: request,
                destination: noteToken,
                calendar: calendar
            )) { error in
                XCTAssertEqual(error as? CaptureCoreAdmissionError, .unsupportedNoteNameToken)
            }
        }
    }

    func test_admissionRejectsAmbiguousShareSourceEntryTokenButPreservesSharedTokens() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        let destinationID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let request = CaptureRequest(
            source: .shareExtension,
            destinationID: destinationID,
            payloads: [.text("payload")]
        )
        var ambiguous = newNoteDestination(id: destinationID)
        ambiguous.entryPrefix = "From {source}\n"
        XCTAssertThrowsError(try CaptureCoreAdmission.admit(
            request: request,
            destination: ambiguous,
            calendar: calendar
        )) { error in
            XCTAssertEqual(error as? CaptureCoreAdmissionError, .unsupportedEntrySourceToken)
        }

        var shared = newNoteDestination(id: destinationID)
        shared.entryPrefix = "{timestamp} {date} {time} {year} {YR} {month} {day} {week} "
            + "{hour} {minute} {second} {id} {id8}\n"
        XCTAssertNoThrow(try CaptureCoreAdmission.admit(
            request: request,
            destination: shared,
            calendar: calendar
        ))
    }

    func test_admissionNarrowsCalendarAndWeekSemanticsAndRejectsUnsupportedTimezones() throws {
        let destinationID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let request = CaptureRequest(
            source: .app,
            destinationID: destinationID,
            payloads: [.text("payload")]
        )

        var dated = newNoteDestination(id: destinationID)
        dated.entryPrefix = "Captured {date}\n"
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: "UTC")!
        gregorian.locale = Locale(identifier: "en_US_POSIX")
        XCTAssertNoThrow(try CaptureCoreAdmission.admit(
            request: request,
            destination: dated,
            calendar: gregorian
        ))

        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(identifier: "UTC")!
        buddhist.locale = Locale(identifier: "en_US_POSIX")
        XCTAssertThrowsError(try CaptureCoreAdmission.admit(
            request: request,
            destination: dated,
            calendar: buddhist
        )) { error in
            XCTAssertEqual(error as? CaptureCoreAdmissionError, .unsupportedCalendarSemantics)
        }
        XCTAssertNoThrow(try CaptureCoreAdmission.admit(
            request: request,
            destination: newNoteDestination(id: destinationID),
            calendar: buddhist
        ))

        var week = newNoteDestination(id: destinationID)
        week.entryPrefix = "Week {week}\n"
        XCTAssertThrowsError(try CaptureCoreAdmission.admit(
            request: request,
            destination: week,
            calendar: gregorian
        )) { error in
            XCTAssertEqual(error as? CaptureCoreAdmissionError, .unsupportedWeekRules)
        }
        gregorian.firstWeekday = 2
        gregorian.minimumDaysInFirstWeek = 4
        XCTAssertNoThrow(try CaptureCoreAdmission.admit(
            request: request,
            destination: week,
            calendar: gregorian
        ))

        var fixedOffset = gregorian
        fixedOffset.timeZone = TimeZone(secondsFromGMT: 3_600)!
        XCTAssertThrowsError(try CaptureCoreAdmission.admit(
            request: request,
            destination: newNoteDestination(id: destinationID),
            calendar: fixedOffset
        )) { error in
            XCTAssertEqual(error as? CaptureCoreAdmissionError, .unsupportedTimeZone)
        }
    }

    func test_shadowCalendarAdmissionFailureFallsBackBeforeSideEffects() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        var destination = newNoteDestination()
        destination.entryPrefix = "{date}\n"
        let request = CaptureRequest(
            source: .app,
            destinationID: destination.id,
            payloads: [.text("legacy")]
        )
        let accounting = EngineRecordingAccounting()
        let noteURL = root.appendingPathComponent("Inbox/note.md")
        let probe = EngineComparisonProbe(
            accounting: accounting,
            observedNoteURL: noteURL,
            comparison: exactComparison
        )
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(identifier: "UTC")!

        _ = try await CapturePipeline(
            pathPlanner: CapturePathPlanner(calendar: buddhist),
            deliveryAccounting: accounting,
            enginePolicy: .shadow(using: probe)
        ).capture(request, destination: destination, rootURL: root)

        let snapshot = await probe.snapshot()
        let events = await accounting.events
        XCTAssertEqual(snapshot.comparisonCount, 0)
        XCTAssertEqual(events, ["reserve", "commit"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: noteURL.path))
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
            payloads: [.text("within the aggregate control budget")]
        )
        let admitted = try CaptureCoreAdmission.admit(
            request: request,
            destination: destination,
            calendar: calendar
        )
        XCTAssertEqual(admitted.payloads.count, 1)
        XCTAssertEqual(admitted.logicalFolder.count, 31)

        var maximumScalarPayload = request
        maximumScalarPayload.payloads = [.text(String(repeating: "é", count: 65_536))]
        XCTAssertNoThrow(try CaptureCoreAdmission.admit(
            request: maximumScalarPayload,
            destination: newNoteDestination(id: destination.id),
            calendar: calendar
        ))

        var maximumCandidateName = newNoteDestination(id: destination.id)
        maximumCandidateName.noteTarget = .newNote(pathTemplate: String(repeating: "n", count: 248))
        XCTAssertNoThrow(try CaptureCoreAdmission.admit(
            request: request,
            destination: maximumCandidateName,
            calendar: calendar
        ))
        for length in [249, 253] {
            var oversizedCandidateName = newNoteDestination(id: destination.id)
            oversizedCandidateName.noteTarget = .newNote(pathTemplate: String(repeating: "n", count: length))
            XCTAssertThrowsError(try CaptureCoreAdmission.admit(
                request: request,
                destination: oversizedCandidateName,
                calendar: calendar
            )) { error in
                XCTAssertEqual(error as? CaptureCoreAdmissionError, .contractBoundExceeded)
            }
        }

        var uppercaseScheme = request
        uppercaseScheme.payloads = [.url(URL(string: "HTTPS://example.invalid/path")!, title: "Example")]
        XCTAssertThrowsError(try CaptureCoreAdmission.admit(
            request: uppercaseScheme,
            destination: newNoteDestination(id: destination.id),
            calendar: calendar
        )) { error in
            XCTAssertEqual(error as? CaptureCoreAdmissionError, .unsupportedPayload)
        }

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

    private func newNoteDestination(id: UUID = UUID()) -> CaptureDestination {
        CaptureDestination(
            id: id,
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
