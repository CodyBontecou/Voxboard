import Foundation

/// Resolves Capture destination bookmarks consistently across the iOS and Mac
/// apps. iOS stores minimal document-picker bookmarks, while sandboxed macOS
/// destinations use security-scoped bookmarks. Tests and legacy local records
/// may still contain ordinary bookmarks, so macOS falls back safely when the
/// scoped resolution form is not applicable.
public enum CaptureBookmarkResolver: Sendable {
    public struct Resolution: Sendable {
        public let url: URL
        public let isStale: Bool

        public init(url: URL, isStale: Bool) {
            self.url = url
            self.isStale = isStale
        }
    }

    public static func resolve(_ bookmarkData: Data) throws -> Resolution {
        #if os(macOS)
        var scopedIsStale = false
        if let scopedURL = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &scopedIsStale
        ) {
            return Resolution(url: scopedURL, isStale: scopedIsStale)
        }
        #endif

        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return Resolution(url: url, isStale: isStale)
    }
}
