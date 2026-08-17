import Foundation

/// Describes where Vox.md reads an installed transcription model from.
public enum ModelInstallationSource: String, Sendable {
    /// A model downloaded into Vox.md's App Group model directory.
    case appManaged
    /// A model kept elsewhere on the Mac and authorized by the user.
    case external
}

/// Keeps a security-scoped external model location accessible for as long as
/// its inference context may read files from that location.
final class InstalledModelAccess: @unchecked Sendable {
    let url: URL
    let source: ModelInstallationSource

    #if os(macOS)
    private let stopsSecurityScopedAccess: Bool
    #endif

    init(url: URL, source: ModelInstallationSource) {
        self.url = url
        self.source = source
        #if os(macOS)
        self.stopsSecurityScopedAccess = source == .external
            && url.startAccessingSecurityScopedResource()
        #endif
    }

    deinit {
        #if os(macOS)
        if stopsSecurityScopedAccess {
            url.stopAccessingSecurityScopedResource()
        }
        #endif
    }
}

#if os(macOS)
/// Persists user-selected model locations without copying the model into the
/// app container. Security-scoped bookmarks are required by the Mac App
/// Sandbox and remain valid across launches.
enum ExternalModelBookmarkStore {
    static func hasBookmark(for modelID: String, defaults: UserDefaults?) -> Bool {
        defaults?.data(forKey: bookmarkKey(for: modelID)) != nil
    }

    static func save(url: URL, for modelID: String, defaults: UserDefaults?) throws {
        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        save(bookmarkData: bookmark, for: modelID, defaults: defaults)
    }

    static func save(bookmarkData: Data, for modelID: String, defaults: UserDefaults?) {
        defaults?.set(bookmarkData, forKey: bookmarkKey(for: modelID))
    }

    static func resolveURL(for modelID: String, defaults: UserDefaults?) -> URL? {
        guard let bookmark = defaults?.data(forKey: bookmarkKey(for: modelID)),
              let resolution = try? CaptureBookmarkResolver.resolve(bookmark) else {
            return nil
        }

        if resolution.isStale {
            refreshBookmarkIfPossible(
                for: resolution.url,
                modelID: modelID,
                defaults: defaults
            )
        }
        return resolution.url.standardizedFileURL
    }

    static func removeBookmark(for modelID: String, defaults: UserDefaults?) {
        defaults?.removeObject(forKey: bookmarkKey(for: modelID))
    }

    private static func bookmarkKey(for modelID: String) -> String {
        "\(AppConstants.externalModelBookmarkKeyPrefix).\(modelID)"
    }

    private static func refreshBookmarkIfPossible(
        for url: URL,
        modelID: String,
        defaults: UserDefaults?
    ) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }
        guard let refreshed = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            return
        }
        save(bookmarkData: refreshed, for: modelID, defaults: defaults)
    }
}
#endif
