import Foundation

#if os(iOS)
import ActivityKit
#endif

/// Serializable state shared by the Live Activity's lock-screen banner and
/// Dynamic Island presentations. Kept platform-independent so it can be
/// unit-tested without ActivityKit.
public struct VoxboardLiveActivityState: Codable, Hashable, Sendable {
    public var isSegmentActive: Bool
    public var isTranscribing: Bool
    public var segmentStartedAt: TimeInterval?
    /// Recorder-owned segment identity used by the Stop intent. Optional so
    /// activities created by older app versions still decode safely.
    public var segmentRequestId: String?

    public init(
        isSegmentActive: Bool = false,
        isTranscribing: Bool = false,
        segmentStartedAt: TimeInterval? = nil,
        segmentRequestId: String? = nil
    ) {
        self.isSegmentActive = isSegmentActive
        self.isTranscribing = isTranscribing
        self.segmentStartedAt = segmentStartedAt
        self.segmentRequestId = segmentRequestId
    }

    public static let idle = VoxboardLiveActivityState(
        isSegmentActive: false,
        isTranscribing: false,
        segmentStartedAt: nil,
        segmentRequestId: nil
    )
}

#if os(iOS)
@available(iOS 16.1, *)
public struct VoxboardActivityAttributes: ActivityAttributes {
    public typealias ContentState = VoxboardLiveActivityState
    public init() {}
}
#endif
