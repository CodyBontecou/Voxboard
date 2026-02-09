import Foundation

/// Persists transcription history as JSON in the App Group shared container.
/// Survives app restarts. Used by both the main app and keyboard extension.
@Observable
public final class TranscriptStore {
    public var transcripts: [Transcript] = []

    private let fileURL: URL? = {
        AppConstants.sharedContainerURL?.appendingPathComponent("transcripts.json")
    }()

    public init() {
        load()
    }

    public func add(_ transcript: Transcript) {
        transcripts.insert(transcript, at: 0)
        save()
    }

    public func delete(at offsets: IndexSet) {
        for index in offsets.sorted().reversed() {
            transcripts.remove(at: index)
        }
        save()
    }

    public func clear() {
        transcripts.removeAll()
        save()
    }

    /// Re-read transcripts from disk (e.g. after another process wrote new data).
    public func reload() {
        load()
    }

    // MARK: - Persistence

    private func save() {
        guard let url = fileURL else { return }
        do {
            let data = try JSONEncoder().encode(transcripts)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[TranscriptStore] Save failed: \(error)")
        }
    }

    private func load() {
        guard let url = fileURL,
              FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            transcripts = try JSONDecoder().decode([Transcript].self, from: data)
        } catch {
            print("[TranscriptStore] Load failed: \(error)")
        }
    }
}
