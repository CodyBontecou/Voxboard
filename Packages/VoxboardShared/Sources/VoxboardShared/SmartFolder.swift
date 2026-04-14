import Foundation

/// A user-defined destination folder paired with a description that Apple
/// Intelligence uses to route transcripts to the most appropriate location.
public struct SmartFolder: Codable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var folderDescription: String
    public var bookmarkData: Data

    public init(
        id: UUID = UUID(),
        name: String,
        folderDescription: String,
        bookmarkData: Data
    ) {
        self.id = id
        self.name = name
        self.folderDescription = folderDescription
        self.bookmarkData = bookmarkData
    }

    /// Resolve the security-scoped folder URL from the stored bookmark.
    /// Returns nil when the bookmark is invalid or the folder no longer exists.
    public func resolveURL() -> URL? {
        var isStale = false
        return try? URL(resolvingBookmarkData: bookmarkData, bookmarkDataIsStale: &isStale)
    }
}
