import Foundation

/// Durable keyboard insertion state restored from the persisted delivery checkpoint.
public struct LiveTranscriptionDeliveryState: Equatable, Sendable {
    public var deliveredText: String
    public var revision: Int

    public init(deliveredText: String = "", revision: Int = 0) {
        self.deliveredText = deliveredText
        self.revision = revision
    }
}

/// Deterministic persist-before-insert transition used by the keyboard extension.
///
/// The checkpoint writer runs before a committed delta is returned. If the
/// extension exits after persistence but before insertion, restart restoration
/// suppresses replay of that delta, deliberately favoring at-most-once insertion.
public enum LiveTranscriptionDeliveryReducer {
    public enum Outcome: Equatable, Sendable {
        case ignoredStale
        case ignoredNonMonotonic
        case persistenceFailed
        case committed(state: LiveTranscriptionDeliveryState, delta: String)
    }

    public static func restoredState(
        from checkpoint: LiveTranscriptionDeliveryCheckpoint?,
        requestID: String
    ) -> LiveTranscriptionDeliveryState {
        guard let checkpoint, checkpoint.requestId == requestID else {
            return LiveTranscriptionDeliveryState()
        }
        return LiveTranscriptionDeliveryState(
            deliveredText: checkpoint.deliveredText,
            revision: checkpoint.revision
        )
    }

    public static func apply(
        _ snapshot: LiveTranscriptionSnapshot,
        requestID: String,
        state: LiveTranscriptionDeliveryState,
        persistCheckpoint: (LiveTranscriptionDeliveryCheckpoint) -> Bool
    ) -> Outcome {
        guard snapshot.requestId == requestID, snapshot.revision > state.revision else {
            return .ignoredStale
        }
        guard snapshot.finalizedText.hasPrefix(state.deliveredText) else {
            return .ignoredNonMonotonic
        }
        let checkpoint = LiveTranscriptionDeliveryCheckpoint(
            requestId: requestID,
            revision: snapshot.revision,
            deliveredText: snapshot.finalizedText
        )
        guard persistCheckpoint(checkpoint) else { return .persistenceFailed }
        return .committed(
            state: LiveTranscriptionDeliveryState(
                deliveredText: snapshot.finalizedText,
                revision: snapshot.revision
            ),
            delta: String(snapshot.finalizedText.dropFirst(state.deliveredText.count))
        )
    }
}
