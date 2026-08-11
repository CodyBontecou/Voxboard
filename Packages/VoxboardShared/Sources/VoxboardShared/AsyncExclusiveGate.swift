import Foundation

/// A cancellation-aware FIFO gate for resources that support only one active
/// async operation. Cancellation removes queued waiters before they acquire the
/// resource, and every acquired operation releases it on success or failure.
actor AsyncExclusiveGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var isLocked = false
    private var waiters: [Waiter] = []

    func withExclusiveAccess<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        try await acquire()
        do {
            // Covers cancellation that races with immediate acquisition.
            try Task.checkCancellation()
            let value = try await operation()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        guard isLocked else {
            isLocked = true
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }

        // The task may be cancelled after release passed ownership to this
        // waiter but before its continuation resumed. Pass ownership onward.
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release() {
        guard isLocked else { return }
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }

        let waiter = waiters.removeFirst()
        // Ownership transfers directly; `isLocked` remains true.
        waiter.continuation.resume()
    }
}
