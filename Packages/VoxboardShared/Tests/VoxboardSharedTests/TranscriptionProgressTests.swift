import XCTest
@testable import VoxboardShared

final class TranscriptionProgressTests: XCTestCase {
    func testPreparingHasNoExactPercentage() {
        let progress = TranscriptionProgress.preparing

        XCTAssertEqual(progress.kind, .preparing)
        XCTAssertNil(progress.exactFractionCompleted)
        XCTAssertNil(progress.wholePercentCompleted)
    }

    func testExactAudioCoverageClampsFiniteFractions() {
        XCTAssertEqual(
            TranscriptionProgress.exactAudioCoverage(-0.5).exactFractionCompleted,
            0
        )
        XCTAssertEqual(
            TranscriptionProgress.exactAudioCoverage(0.429).exactFractionCompleted,
            0.429
        )
        XCTAssertEqual(
            TranscriptionProgress.exactAudioCoverage(1.5).exactFractionCompleted,
            1
        )
        XCTAssertEqual(
            TranscriptionProgress.exactAudioCoverage(0.429).wholePercentCompleted,
            42
        )
    }

    func testNonFiniteCoverageBecomesIndeterminate() {
        for value in [Double.nan, Double.infinity, -Double.infinity] {
            let progress = TranscriptionProgress.exactAudioCoverage(value)
            XCTAssertEqual(progress.kind, .preparing)
            XCTAssertNil(progress.exactFractionCompleted)
        }
    }

    func testFormattedPercentPreservesFloorSemantics() {
        let progress = TranscriptionProgress.exactAudioCoverage(0.999)

        XCTAssertEqual(progress.wholePercentCompleted, 99)
        XCTAssertNotNil(progress.formattedWholePercentCompleted)
        XCTAssertEqual(
            progress.formattedWholePercentCompleted,
            0.99.formatted(.percent.precision(.fractionLength(0)))
        )
    }

    // A model-backed short-then-long regression requires downloaded FluidAudio
    // weights, so these tests cover the subscription boundary without inference.
    func testParakeetProgressPolicySkipsShortAudio() {
        XCTAssertFalse(
            ParakeetProgressObservationPolicy.shouldObserve(audioDuration: 14.999)
        )
    }

    func testParakeetProgressPolicySkipsExactBoundary() {
        XCTAssertFalse(
            ParakeetProgressObservationPolicy.shouldObserve(audioDuration: 15)
        )
    }

    func testParakeetProgressPolicyObservesLongAudio() {
        XCTAssertTrue(
            ParakeetProgressObservationPolicy.shouldObserve(audioDuration: 15.001)
        )
    }

    func testParakeetProgressPolicySkipsUnknownDuration() {
        XCTAssertFalse(
            ParakeetProgressObservationPolicy.shouldObserve(audioDuration: nil)
        )
    }

    func testProgressRelayRejectsDuplicatesRegressionsAndPrematureCompletion() {
        var relay = MonotonicAudioCoverageProgressRelay()

        XCTAssertEqual(relay.accept(0)?.exactFractionCompleted, 0)
        XCTAssertNil(relay.accept(0))
        XCTAssertEqual(relay.accept(0.4)?.exactFractionCompleted, 0.4)
        XCTAssertNil(relay.accept(0.3))
        XCTAssertNil(relay.accept(.nan))
        XCTAssertNil(relay.accept(1))
        XCTAssertEqual(relay.accept(0.9)?.exactFractionCompleted, 0.9)
    }

    #if os(iOS) || os(macOS)
    func testWhisperProgressRelayNormalizesAndReservesCompletion() {
        var relay = WhisperAudioCoverageProgressRelay()
        let accepted = [-1, 0, 0, 42, 41, 99, 100, 101]
            .compactMap { relay.accept(Int32($0))?.exactFractionCompleted }

        XCTAssertEqual(accepted, [0, 0.42, 0.99])
    }
    #endif

    func testExclusiveGateSerializesOperations() async throws {
        let gate = AsyncExclusiveGate()
        let tracker = ExclusiveGateTracker()
        let firstEntered = AsyncTestLatch()
        let releaseFirst = AsyncTestLatch()

        let first = Task {
            try await gate.withExclusiveAccess {
                await tracker.enter("first")
                await firstEntered.open()
                await releaseFirst.wait()
                await tracker.leave()
            }
        }
        await firstEntered.wait()

        let second = Task {
            try await gate.withExclusiveAccess {
                await tracker.enter("second")
                await tracker.leave()
            }
        }
        await releaseFirst.open()

        try await first.value
        try await second.value
        let snapshot = await tracker.snapshot()
        XCTAssertEqual(snapshot.maximumActive, 1)
        XCTAssertEqual(snapshot.entries, ["first", "second"])
    }

    func testExclusiveGateCancelledWaiterNeverRuns() async throws {
        let gate = AsyncExclusiveGate()
        let tracker = ExclusiveGateTracker()
        let firstEntered = AsyncTestLatch()
        let releaseFirst = AsyncTestLatch()

        let first = Task {
            try await gate.withExclusiveAccess {
                await tracker.enter("first")
                await firstEntered.open()
                await releaseFirst.wait()
                await tracker.leave()
            }
        }
        await firstEntered.wait()

        let cancelled = Task {
            try await gate.withExclusiveAccess {
                await tracker.enter("cancelled")
                await tracker.leave()
            }
        }
        await Task.yield()
        cancelled.cancel()
        await releaseFirst.open()

        try await first.value
        do {
            try await cancelled.value
            XCTFail("Expected the queued waiter to be cancelled")
        } catch is CancellationError {
            // Expected.
        }

        try await gate.withExclusiveAccess {
            await tracker.enter("after")
            await tracker.leave()
        }
        let snapshot = await tracker.snapshot()
        XCTAssertEqual(snapshot.maximumActive, 1)
        XCTAssertEqual(snapshot.entries, ["first", "after"])
    }

    func testExclusiveGateReleasesWhenActiveOperationIsCancelled() async throws {
        let gate = AsyncExclusiveGate()
        let entered = AsyncTestLatch()

        let active = Task {
            try await gate.withExclusiveAccess {
                await entered.open()
                try await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
        await entered.wait()
        active.cancel()

        do {
            try await active.value
            XCTFail("Expected the active operation to be cancelled")
        } catch is CancellationError {
            // Expected.
        }

        let value = try await gate.withExclusiveAccess { 42 }
        XCTAssertEqual(value, 42)
    }
}

private actor AsyncTestLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor ExclusiveGateTracker {
    private var active = 0
    private var maximumActive = 0
    private var entries: [String] = []

    func enter(_ name: String) {
        active += 1
        maximumActive = max(maximumActive, active)
        entries.append(name)
    }

    func leave() {
        active -= 1
    }

    func snapshot() -> (maximumActive: Int, entries: [String]) {
        (maximumActive, entries)
    }
}
