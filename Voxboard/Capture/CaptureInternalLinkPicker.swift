import Foundation
import SwiftUI
import VoxboardShared

struct CaptureVaultNote: Identifiable, Equatable, Sendable {
    var relativePath: String
    var id: String { relativePath }
    var wikiTarget: String { String(relativePath.dropLast(3)) }
    var displayName: String { URL(fileURLWithPath: relativePath).deletingPathExtension().lastPathComponent }
}

actor CaptureVaultNoteIndex {
    private let maximumNotes: Int
    private let fileManager: FileManager

    init(maximumNotes: Int = 5_000, fileManager: FileManager = .default) {
        self.maximumNotes = maximumNotes
        self.fileManager = fileManager
    }

    func notes(in rootURL: URL) throws -> [CaptureVaultNote] {
        let didAccess = rootURL.startAccessingSecurityScopedResource()
        defer { if didAccess { rootURL.stopAccessingSecurityScopedResource() } }
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        let rootPath = rootURL.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        var result: [CaptureVaultNote] = []
        while let url = enumerator.nextObject() as? URL, result.count < maximumNotes {
            guard url.pathExtension.lowercased() == "md" else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isHiddenKey])
            guard values?.isRegularFile == true, values?.isHidden != true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            let relativePath = String(path.dropFirst(prefix.count))
            guard (try? CapturePathValidation.validateRelativePath(relativePath)) != nil else { continue }
            result.append(CaptureVaultNote(relativePath: relativePath))
        }
        return result.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }
}

struct CaptureInternalLinkPicker: View {
    var rootURL: URL?
    var onInsert: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var customTarget = ""
    @State private var notes: [CaptureVaultNote] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var filteredNotes: [CaptureVaultNote] {
        guard !query.isEmpty else { return notes }
        return notes.filter {
            $0.relativePath.localizedCaseInsensitiveContains(query)
                || $0.displayName.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Quick links") {
                    Button {
                        let formatter = DateFormatter()
                        formatter.locale = Locale(identifier: "en_US_POSIX")
                        formatter.dateFormat = "yyyy-MM-dd"
                        insert(formatter.string(from: Date()))
                    } label: {
                        Label("Insert today’s date", systemImage: "calendar")
                    }

                    HStack {
                        TextField("Write my own", text: $customTarget)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Insert") { insert(customTarget) }
                            .disabled(customTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                Section("Insert filename from vault") {
                    if isLoading {
                        HStack {
                            ProgressView()
                            Text("Indexing filenames on device…")
                        }
                    } else if let errorMessage {
                        Text(errorMessage).foregroundStyle(Geist.error)
                    } else if filteredNotes.isEmpty {
                        Text(rootURL == nil
                             ? String(localized: "Choose a destination first.")
                             : String(localized: "No Markdown notes found."))
                            .foregroundStyle(Geist.muted)
                    } else {
                        ForEach(filteredNotes) { note in
                            Button {
                                insert(note.wikiTarget)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(note.displayName)
                                    Text(note.relativePath)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(Geist.muted)
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search filenames")
            .navigationTitle("[[Internal links]]")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await loadNotes() }
        }
    }

    private func loadNotes() async {
        guard let rootURL else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            notes = try await CaptureVaultNoteIndex().notes(in: rootURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func insert(_ rawTarget: String) {
        do {
            let markdown = try CaptureInsertionFormatter().wikiLink(for: rawTarget)
            onInsert(markdown)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
