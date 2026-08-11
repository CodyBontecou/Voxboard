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

    /// Local folder name used by FluidAudio when caching Parakeet CoreML models on disk.
    /// Nil for Whisper models (they use a single `.bin` file identified by `fileName`).
    public var parakeetRepoFolderName: String? {
        switch self {
        case .parakeetV2: return "parakeet-tdt-0.6b-v2"
        case .parakeetV3: return "parakeet-tdt-0.6b-v3"
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

    /// Shared vocabulary file required by FluidAudio's Parakeet loader.
    public static let parakeetVocabularyFile = "parakeet_vocab.json"

    /// Internal files required before a compiled Core ML bundle is considered complete.
    public static let parakeetRequiredBundleFiles: [String] = [
        "coremldata.bin",
        "metadata.json",
        "model.mil",
        "weights/weight.bin",
    ]

    /// Trusted sizes for the artifacts FluidAudio 0.13.4 loads. These turn
    /// structural checks into deterministic completeness checks and let retries
    /// remove invalid paths that FluidAudio would otherwise skip merely because
    /// they exist.
    var parakeetExpectedArtifactSizes: [String: Int64]? {
        switch self {
        case .whisper:
            return nil
        case .parakeetV2:
            return [
                "Preprocessor.mlmodelc/coremldata.bin": 494,
                "Preprocessor.mlmodelc/metadata.json": 2_974,
                "Preprocessor.mlmodelc/model.mil": 27_166,
                "Preprocessor.mlmodelc/weights/weight.bin": 298_880,
                "Encoder.mlmodelc/coremldata.bin": 485,
                "Encoder.mlmodelc/metadata.json": 2_926,
                "Encoder.mlmodelc/model.mil": 959_769,
                "Encoder.mlmodelc/weights/weight.bin": 445_187_200,
                "Decoder.mlmodelc/coremldata.bin": 554,
                "Decoder.mlmodelc/metadata.json": 3_427,
                "Decoder.mlmodelc/model.mil": 13_106,
                "Decoder.mlmodelc/weights/weight.bin": 14_429_952,
                "JointDecision.mlmodelc/coremldata.bin": 534,
                "JointDecision.mlmodelc/metadata.json": 2_936,
                "JointDecision.mlmodelc/model.mil": 9_722,
                "JointDecision.mlmodelc/weights/weight.bin": 3_453_388,
                Self.parakeetVocabularyFile: 18_762,
            ]
        case .parakeetV3:
            return [
                "Preprocessor.mlmodelc/coremldata.bin": 486,
                "Preprocessor.mlmodelc/metadata.json": 2_841,
                "Preprocessor.mlmodelc/model.mil": 28_181,
                "Preprocessor.mlmodelc/weights/weight.bin": 491_072,
                "Encoder.mlmodelc/coremldata.bin": 485,
                "Encoder.mlmodelc/metadata.json": 2_921,
                "Encoder.mlmodelc/model.mil": 959_769,
                "Encoder.mlmodelc/weights/weight.bin": 445_187_200,
                "Decoder.mlmodelc/coremldata.bin": 554,
                "Decoder.mlmodelc/metadata.json": 3_427,
                "Decoder.mlmodelc/model.mil": 13_110,
                "Decoder.mlmodelc/weights/weight.bin": 23_604_992,
                "JointDecision.mlmodelc/coremldata.bin": 534,
                "JointDecision.mlmodelc/metadata.json": 2_936,
                "JointDecision.mlmodelc/model.mil": 9_723,
                "JointDecision.mlmodelc/weights/weight.bin": 12_642_764,
                Self.parakeetVocabularyFile: 151_122,
            ]
        }
    }
}

/// Metadata for a transcription model (Whisper GGML or Parakeet CoreML).
public struct WhisperModelInfo: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    /// For Whisper: the `.bin` file name.
    /// For Parakeet: the repo folder name (same as `engine.parakeetRepoFolderName`).
    public let fileName: String
    public let sizeLabel: String
    /// Exact bytes for Whisper files and a conservative download estimate for
    /// multi-file Parakeet repositories. Whisper uses this for integrity checks;
    /// every model uses it for available-capacity preflight.
    public let downloadSizeBytes: Int64?
    /// Optional per-model details shown in the model picker UI.
    public let modelDescription: String?
    /// Informational URL. Whisper downloads use this directly; Parakeet downloads
    /// are handled by FluidAudio's DownloadUtils instead.
    public let downloadURL: URL
    public let isBundled: Bool
    /// Which inference engine this model uses (default `.whisper` for backward compat).
    public let engine: ModelEngine

    public var localizedModelDescription: String? {
        switch modelDescription {
        case "Optimized for English.":
            return String(localized: "Optimized for English.", bundle: .main)
        case "Supports 25 languages.":
            return String(localized: "Supports 25 languages.", bundle: .main)
        default:
            return modelDescription
        }
    }

    public init(
        id: String,
        name: String,
        fileName: String,
        sizeLabel: String,
        downloadSizeBytes: Int64? = nil,
        modelDescription: String? = nil,
        downloadURL: URL,
        isBundled: Bool,
        engine: ModelEngine = .whisper
    ) {
        self.id = id
        self.name = name
        self.fileName = fileName
        self.sizeLabel = sizeLabel
        self.downloadSizeBytes = downloadSizeBytes
        self.modelDescription = modelDescription
        self.downloadURL = downloadURL
        self.isBundled = isBundled
        self.engine = engine
    }

    // MARK: - Derived properties

    public var isDownloaded: Bool {
        guard let modelsDir = AppConstants.modelsDirectoryURL else { return false }
        return isDownloaded(in: modelsDir)
    }

    /// Testable completeness check that does not depend on an App Group container.
    public func isDownloaded(in modelsDirectory: URL) -> Bool {
        if engine.isParakeet {
            guard let folder = engine.parakeetRepoFolderName,
                  let expectedArtifacts = engine.parakeetExpectedArtifactSizes else { return false }
            let repoDirectory = modelsDirectory.appendingPathComponent(folder)
            return expectedArtifacts.allSatisfy { relativePath, expectedByteCount in
                Self.fileSize(at: repoDirectory.appendingPathComponent(relativePath))
                    == expectedByteCount
            }
        }

        let modelURL = modelsDirectory.appendingPathComponent(fileName)
        guard Self.hasNonemptyFile(at: modelURL) else { return false }
        guard let expectedByteCount = downloadSizeBytes else { return true }
        return Self.fileSize(at: modelURL) == expectedByteCount
    }

    /// Existing invalid paths must be removed before invoking FluidAudio 0.13.4,
    /// whose downloader skips any path that already exists. Missing paths are
    /// left alone so FluidAudio downloads them normally.
    func removeInvalidExistingParakeetArtifacts(in modelsDirectory: URL) throws {
        guard let folder = engine.parakeetRepoFolderName,
              let expectedArtifacts = engine.parakeetExpectedArtifactSizes else { return }
        let repoDirectory = modelsDirectory.appendingPathComponent(folder)

        for (relativePath, expectedByteCount) in expectedArtifacts {
            let artifactURL = repoDirectory.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: artifactURL.path),
                  Self.fileSize(at: artifactURL) != expectedByteCount else { continue }
            try FileManager.default.removeItem(at: artifactURL)
        }
    }

    private static func hasNonemptyFile(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return false }
        return (fileSize(at: url) ?? 0) > 0
    }

    private static func fileSize(at url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        return (attributes[.size] as? NSNumber)?.int64Value
    }

    /// For Whisper: path to the `.bin` file.
    /// For Parakeet: path to the local FluidAudio repo directory (e.g. `…/parakeet-tdt-0.6b-v3`).
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
            downloadSizeBytes: 77_691_713,
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin")!,
            isBundled: false
        ),
        WhisperModelInfo(
            id: "ggml-base",
            name: "Base",
            fileName: "ggml-base.bin",
            sizeLabel: "142 MB",
            downloadSizeBytes: 147_951_465,
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin")!,
            isBundled: false
        ),
        WhisperModelInfo(
            id: "ggml-small",
            name: "Small",
            fileName: "ggml-small.bin",
            sizeLabel: "466 MB",
            downloadSizeBytes: 487_601_967,
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin")!,
            isBundled: false
        ),
        WhisperModelInfo(
            id: "ggml-medium",
            name: "Medium",
            fileName: "ggml-medium.bin",
            sizeLabel: "1.5 GB",
            downloadSizeBytes: 1_533_763_059,
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin")!,
            isBundled: false
        ),
        WhisperModelInfo(
            id: "ggml-large-v3-turbo",
            name: "Large v3 Turbo",
            fileName: "ggml-large-v3-turbo.bin",
            sizeLabel: "1.6 GB",
            downloadSizeBytes: 1_624_555_275,
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!,
            isBundled: false
        ),

        // ── Parakeet models (NVIDIA TDT via FluidAudio CoreML) ─────────────────
        WhisperModelInfo(
            id: "parakeet-v2",
            name: "Parakeet v2",
            fileName: "parakeet-tdt-0.6b-v2",
            sizeLabel: "~800 MB",
            downloadSizeBytes: 800_000_000,
            modelDescription: "Optimized for English.",
            downloadURL: URL(string: "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml")!,
            isBundled: false,
            engine: .parakeetV2
        ),
        WhisperModelInfo(
            id: "parakeet-v3",
            name: "Parakeet v3",
            fileName: "parakeet-tdt-0.6b-v3",
            sizeLabel: "~800 MB",
            downloadSizeBytes: 800_000_000,
            modelDescription: "Supports 25 languages.",
            downloadURL: URL(string: "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml")!,
            isBundled: false,
            engine: .parakeetV3
        ),
    ]
}
