import Foundation

/// Shared denial-of-service limits for capture entry points. Individual files
/// also pass through `CaptureAssetStager.defaultMaximumByteCount`.
public enum CaptureInputLimits: Sendable {
    public static let maximumTextCharacters = 100_000
    public static let maximumSharedItemCount = 10
    public static let maximumAggregateAssetByteCount: Int64 = 250 * 1_024 * 1_024
}

public enum CaptureInputLimitError: Error, Equatable, LocalizedError, Sendable {
    case tooManySharedItems(count: Int, limit: Int)
    case textTooLarge(characters: Int, limit: Int)
    case assetsTooLarge(bytes: Int64, limit: Int64)
    case invalidNegativeCount

    public var errorDescription: String? {
        switch self {
        case .tooManySharedItems(let count, let limit):
            return "This capture contains \(count) shared items; the safety limit is \(limit)."
        case .textTooLarge(_, let limit):
            return "Shared text is above the \(limit.formatted())-character safety limit."
        case .assetsTooLarge(_, let limit):
            return "Shared files exceed the \((limit / 1_024 / 1_024).formatted()) MB total safety limit."
        case .invalidNegativeCount:
            return "Capture input sizes cannot be negative."
        }
    }
}

/// Tracks cumulative input before a capture is accepted. Reservations are
/// transactional: a rejected value never changes the recorded totals.
public struct CaptureInputBudget: Equatable, Sendable {
    public private(set) var sharedItemCount: Int = 0
    public private(set) var textCharacterCount: Int = 0
    public private(set) var assetByteCount: Int64 = 0

    public init() {}

    public mutating func reserveSharedItems(_ count: Int) throws {
        guard count >= 0 else { throw CaptureInputLimitError.invalidNegativeCount }
        let (total, overflow) = sharedItemCount.addingReportingOverflow(count)
        guard !overflow, total <= CaptureInputLimits.maximumSharedItemCount else {
            throw CaptureInputLimitError.tooManySharedItems(
                count: overflow ? Int.max : total,
                limit: CaptureInputLimits.maximumSharedItemCount
            )
        }
        sharedItemCount = total
    }

    public mutating func reserveText(characters: Int) throws {
        guard characters >= 0 else { throw CaptureInputLimitError.invalidNegativeCount }
        let (total, overflow) = textCharacterCount.addingReportingOverflow(characters)
        guard !overflow, total <= CaptureInputLimits.maximumTextCharacters else {
            throw CaptureInputLimitError.textTooLarge(
                characters: overflow ? Int.max : total,
                limit: CaptureInputLimits.maximumTextCharacters
            )
        }
        textCharacterCount = total
    }

    public mutating func reserveAsset(bytes: Int64) throws {
        guard bytes >= 0 else { throw CaptureInputLimitError.invalidNegativeCount }
        let (total, overflow) = assetByteCount.addingReportingOverflow(bytes)
        guard !overflow, total <= CaptureInputLimits.maximumAggregateAssetByteCount else {
            throw CaptureInputLimitError.assetsTooLarge(
                bytes: overflow ? Int64.max : total,
                limit: CaptureInputLimits.maximumAggregateAssetByteCount
            )
        }
        assetByteCount = total
    }
}
