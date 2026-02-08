import Foundation

/// Metadata for a whisper.cpp GGML model.
public struct WhisperModelInfo: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let fileName: String
    public let sizeLabel: String
    public let downloadURL: URL
    public let isBundled: Bool

    public var isDownloaded: Bool {
        guard let modelsDir = AppConstants.modelsDirectoryURL else { return false }
        return FileManager.default.fileExists(atPath: modelsDir.appendingPathComponent(fileName).path)
    }

    public var localURL: URL? {
        AppConstants.modelsDirectoryURL?.appendingPathComponent(fileName)
    }

    public static let availableModels: [WhisperModelInfo] = [
        WhisperModelInfo(
            id: "ggml-tiny",
            name: "Tiny",
            fileName: "ggml-tiny.bin",
            sizeLabel: "75 MB",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin")!,
            isBundled: false
        ),
        WhisperModelInfo(
            id: "ggml-base",
            name: "Base",
            fileName: "ggml-base.bin",
            sizeLabel: "142 MB",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin")!,
            isBundled: true
        ),
        WhisperModelInfo(
            id: "ggml-small",
            name: "Small",
            fileName: "ggml-small.bin",
            sizeLabel: "466 MB",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin")!,
            isBundled: false
        ),
        WhisperModelInfo(
            id: "ggml-medium",
            name: "Medium",
            fileName: "ggml-medium.bin",
            sizeLabel: "1.5 GB",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin")!,
            isBundled: false
        ),
        WhisperModelInfo(
            id: "ggml-large-v3-turbo",
            name: "Large v3 Turbo",
            fileName: "ggml-large-v3-turbo.bin",
            sizeLabel: "1.6 GB",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!,
            isBundled: false
        ),
    ]
}
