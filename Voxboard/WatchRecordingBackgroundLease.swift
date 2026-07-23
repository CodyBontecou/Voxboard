import Foundation
import os.log
import UIKit

nonisolated private let watchRecordingBackgroundLog = Logger(
    subsystem: "bontecou.Voxboard",
    category: "WatchRecordingBackground"
)

/// Injectable boundary around UIKit's finite background-execution API.
///
/// `UIApplication` is MainActor-isolated, but its background-task begin/end
/// methods are explicitly nonisolated. The live client captures the application
/// while it is created on MainActor, then safely exposes only those methods.
nonisolated protocol WatchRecordingBackgroundTaskServicing: Sendable {
    func begin(
        name: String,
        expirationHandler: @escaping @MainActor @Sendable () -> Void
    ) -> UIBackgroundTaskIdentifier

    func end(_ identifier: UIBackgroundTaskIdentifier)
}

nonisolated struct WatchRecordingBackgroundTaskClient: WatchRecordingBackgroundTaskServicing, @unchecked Sendable {
    private let application: UIApplication

    @MainActor
    static func live() -> WatchRecordingBackgroundTaskClient {
        WatchRecordingBackgroundTaskClient(application: .shared)
    }

    private init(application: UIApplication) {
        self.application = application
    }

    func begin(
        name: String,
        expirationHandler: @escaping @MainActor @Sendable () -> Void
    ) -> UIBackgroundTaskIdentifier {
        application.beginBackgroundTask(
            withName: name,
            expirationHandler: expirationHandler
        )
    }

    func end(_ identifier: UIBackgroundTaskIdentifier) {
        application.endBackgroundTask(identifier)
    }
}

nonisolated enum WatchRecordingBackgroundExecutionPolicy {
    static func shouldStart(
        leaseIsActive: Bool,
        applicationIsActive: Bool
    ) -> Bool {
        leaseIsActive || applicationIsActive
    }
}

/// Exactly-once ownership for one UIKit background-task identifier.
///
/// A lease may begin on WatchConnectivity's delegate queue, expire on
/// MainActor, and finish from either queue. Its lock protects only the compact
/// state transition; callbacks and UIKit calls always happen after unlocking.
nonisolated final class WatchRecordingBackgroundLease: @unchecked Sendable {
    enum EndReason: String, Sendable {
        case completed
        case coalesced
        case noProcessableWork
        case enqueueFailed
        case pipelineUnavailable
        case unavailable
        case expired
    }

    let token: UUID
    let recordingID: String?

    private enum State {
        case starting
        case active(UIBackgroundTaskIdentifier)
        case ended(EndReason)
    }

    private let service: any WatchRecordingBackgroundTaskServicing
    private let expirationCallback: @MainActor @Sendable (UUID) -> Void
    private let lock = NSLock()
    private var state: State = .starting

    private init(
        token: UUID = UUID(),
        recordingID: String?,
        service: any WatchRecordingBackgroundTaskServicing,
        expirationCallback: @escaping @MainActor @Sendable (UUID) -> Void
    ) {
        self.token = token
        self.recordingID = recordingID
        self.service = service
        self.expirationCallback = expirationCallback
    }

    static func begin(
        recordingID: String?,
        service: any WatchRecordingBackgroundTaskServicing,
        onExpiration: @escaping @MainActor @Sendable (UUID) -> Void
    ) -> WatchRecordingBackgroundLease {
        let lease = WatchRecordingBackgroundLease(
            recordingID: recordingID,
            service: service,
            expirationCallback: onExpiration
        )
        let suffix = recordingID.map { String($0.prefix(8)) } ?? "unknown"
        let identifier = service.begin(name: "WatchRecordingDelivery-\(suffix)") { [weak lease] in
            lease?.expire()
        }
        lease.install(identifier)
        return lease
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .active = state else { return false }
        return true
    }

    var endReason: EndReason? {
        lock.lock()
        defer { lock.unlock() }
        guard case .ended(let reason) = state else { return nil }
        return reason
    }

    func end(_ reason: EndReason) {
        let identifier: UIBackgroundTaskIdentifier?
        lock.lock()
        switch state {
        case .starting:
            state = .ended(reason)
            identifier = nil
        case .active(let activeIdentifier):
            state = .ended(reason)
            identifier = activeIdentifier
        case .ended:
            identifier = nil
        }
        lock.unlock()

        if let identifier, identifier != .invalid {
            service.end(identifier)
            watchRecordingBackgroundLog.notice(
                "Ended background lease token=\(self.token.uuidString, privacy: .public) reason=\(reason.rawValue, privacy: .public)"
            )
        }
    }

    private func install(_ identifier: UIBackgroundTaskIdentifier) {
        var shouldEndImmediately = false
        var endedReason: EndReason?

        lock.lock()
        switch state {
        case .starting:
            if identifier == .invalid {
                state = .ended(.unavailable)
                endedReason = .unavailable
            } else {
                state = .active(identifier)
            }
        case .ended(let reason):
            shouldEndImmediately = identifier != .invalid
            endedReason = reason
        case .active:
            assertionFailure("A Watch recording background lease was installed twice")
            shouldEndImmediately = identifier != .invalid
            endedReason = .coalesced
        }
        lock.unlock()

        if shouldEndImmediately {
            service.end(identifier)
        }

        if identifier == .invalid {
            watchRecordingBackgroundLog.warning(
                "Background lease unavailable token=\(self.token.uuidString, privacy: .public)"
            )
        } else if let endedReason {
            watchRecordingBackgroundLog.notice(
                "Background lease ended during acquisition token=\(self.token.uuidString, privacy: .public) reason=\(endedReason.rawValue, privacy: .public)"
            )
        } else {
            watchRecordingBackgroundLog.notice(
                "Acquired background lease token=\(self.token.uuidString, privacy: .public) recording=\(self.recordingID ?? "unknown", privacy: .public)"
            )
        }
    }

    @MainActor
    private func expire() {
        let identifier: UIBackgroundTaskIdentifier?
        let didExpire: Bool
        lock.lock()
        switch state {
        case .starting:
            state = .ended(.expired)
            identifier = nil
            didExpire = true
        case .active(let activeIdentifier):
            state = .ended(.expired)
            identifier = activeIdentifier
            didExpire = true
        case .ended:
            identifier = nil
            didExpire = false
        }
        lock.unlock()

        guard didExpire else { return }

        expirationCallback(token)
        if let identifier, identifier != .invalid {
            service.end(identifier)
        }
        watchRecordingBackgroundLog.error(
            "Background lease expired token=\(self.token.uuidString, privacy: .public) recording=\(self.recordingID ?? "unknown", privacy: .public)"
        )
    }
}
