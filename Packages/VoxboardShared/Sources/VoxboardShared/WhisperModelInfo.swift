import Foundation

/// Which inference engine powers a model.
public enum ModelEngine: String, Codable, Hashable, Sendable {
    /// whisper.cpp GGML model (existing engine)
    case whisper
    /// NVIDIA Parakeet TDT v2 via FluidAudio CoreML (FluidInference/parakeet-tdt-0.6b-v2-coreml)
    case parakeetV2
    /// NVIDIA Parakeet TDT v3 via FluidAudio CoreML (FluidInference/parakeet-tdt-0.6b-v3-coreml)
    case parakeetV3

    /// True if this model runs through the Parakeet / FluidAudio pipeline.
    public var isParakeet: Bool {
        self == .parakeetV2 || self == .parakeetV3
    }

    /// HuggingFace repo folder name used when storing Parakeet CoreML models on disk.
    /// Nil for Whisper models (they use a single `.bin` file identified by `fileName`).
    public var parakeetRepoFolderName: String? {
        switch self {
        case .parakeetV2: return "parakeet-tdt-0.6b-v2-coreml"
        case .parakeetV3: return "parakeet-tdt-0.6b-v3-coreml"
        case .whisper:    return nil
        }
    }

    /// The four `.mlmodelc` directories required for a complete Parakeet download.
    public static let parakeetRequiredModelDirs: [String] = [
        "Preprocessor.mlmodelc",
        "Encoder.mlmodelc",
        "Decoder.mlmodelc",
        "JointDecision.mlmodelc",
    ]
}

/// Metadata for a transcription model (Whisper GGML or Parakeet CoreML).
public struct WhisperModelInfo: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    /// For Whisper: the `.bin` file name.
    /// For Parakeet: the repo folder name (same as `engine.parakeetRepoFolderName`).
    public let fileName: String
    public let sizeLabel: String
    /// Informational URL. Whisper downloads use this directly; Parakeet downloads
    /// are handled by FluidAudio's DownloadUtils instead.
    public let downloadURL: URL
    public let isBundled: Bool
    /// Which inference engine this model uses (default `.whisper` for backward compat).
    public let engine: ModelEngine

    public init(
        id: String,
        name: String,
        fileName: String,
        sizeLabel: String,
        downloadURL: URL,
        isBundled: Bool,
        engine: ModelEngine = .whisper
    ) {
        self.id = id
        self.name = name
        self.fileName = fileName
        self.sizeLabel = sizeLabel
        self.downloadURL = downloadURL
        self.isBundled = isBundled
        self.engine = engine
    }

    // MARK: - Derived properties

    public var isDownloaded: Bool {
        guard let modelsDir = AppConstants.modelsDirectoryURL else { return false }
        if engine.isParakeet {
            guard let folder = engine.parakeetRepoFolderName else { return false }
            let repoDir = modelsDir.appendingPathComponent(folder)
            return ModelEngine.parakeetRequiredModelDirs.allSatisfy {
                FileManager.default.fileExists(
                    atPath: repoDir.appendingPathComponent($0).path)
            }
        } else {
            return FileManager.default.fileExists(
                atPath: modelsDir.appendingPathComponent(fileName).path)
        }
    }

    /// For Whisper: path to the `.bin` file.
    /// For Parakeet: path to the repo directory (e.g. `…/parakeet-tdt-0.6b-v3-coreml`).
    public var localURL: URL? {
        guard let modelsDir = AppConstants.modelsDirectoryURL else { return nil }
        if engine.isParakeet {
            guard let folder = engine.parakeetRepoFolderName else { return nil }
            return modelsDir.appendingPathComponent(folder)
        } else {
            return modelsDir.appendingPathComponent(fileName)
        }
    }

    // MARK: - Model registry

    public static let availableModels: [WhisperModelInfo] = [
        // ── Whisper models ──────────────────────────────────────────────────────
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

        // ── Parakeet models (NVIDIA TDT via FluidAudio CoreML) ─────────────────
        WhisperModelInfo(
            id: "parakeet-v2",
            name: "Parakeet v2",
            fileName: "parakeet-tdt-0.6b-v2-coreml",
            sizeLabel: "~800 MB",
            downloadURL: URL(string: "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml")!,
            isBundled: false,
            engine: .parakeetV2
        ),
        WhisperModelInfo(
            id: "parakeet-v3",
            name: "Parakeet v3",
            fileName: "parakeet-tdt-0.6b-v3-coreml",
            sizeLabel: "~800 MB",
            downloadURL: URL(string: "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml")!,
            isBundled: false,
            engine: .parakeetV3
        ),
    ]
}
