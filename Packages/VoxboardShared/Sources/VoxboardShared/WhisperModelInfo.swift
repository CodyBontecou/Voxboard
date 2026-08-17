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
    /// Trusted leading bytes for catalog Whisper binaries. This rejects a
    /// different or obviously corrupt same-sized file without hashing gigabytes
    /// every time the Models UI refreshes.
    let trustedFileHeader: Data?
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
        trustedFileHeader: Data? = nil,
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
        self.trustedFileHeader = trustedFileHeader
        self.modelDescription = modelDescription
        self.downloadURL = downloadURL
        self.isBundled = isBundled
        self.engine = engine
    }

    // MARK: - Derived properties

    public var isDownloaded: Bool {
        installedModelAccess(defaults: AppConstants.sharedDefaults) != nil
    }

    /// Testable completeness check for an app-managed installation that does
    /// not depend on an App Group container.
    public func isDownloaded(in modelsDirectory: URL) -> Bool {
        isValidInstallation(at: appManagedURL(in: modelsDirectory))
    }

    /// Validates a user-selected model at its exact file or repository URL.
    /// External Whisper filenames may differ, but their trusted byte count must
    /// match the selected catalog model. Parakeet directories must contain the
    /// complete compiled repository expected by FluidAudio.
    public func isValidInstallation(at url: URL) -> Bool {
        if engine.isParakeet {
            guard let expectedArtifacts = engine.parakeetExpectedArtifactSizes,
                  expectedArtifacts.allSatisfy({ relativePath, expectedByteCount in
                      Self.fileSize(at: url.appendingPathComponent(relativePath))
                          == expectedByteCount
                  }) else {
                return false
            }
            let jsonArtifacts = expectedArtifacts.keys.filter {
                URL(fileURLWithPath: $0).pathExtension.lowercased() == "json"
            }
            return jsonArtifacts.allSatisfy {
                Self.hasValidParakeetJSON(at: url.appendingPathComponent($0))
            }
        }

        guard Self.hasNonemptyFile(at: url) else { return false }
        if let expectedByteCount = downloadSizeBytes,
           Self.fileSize(at: url) != expectedByteCount {
            return false
        }
        if let trustedFileHeader,
           !Self.file(at: url, startsWith: trustedFileHeader) {
            return false
        }
        return true
    }

    /// Resolves the preferred usable installation. A valid user-authorized
    /// external location takes precedence over an app-managed copy so linking
    /// a model actually avoids the duplicate installation.
    func installedModelAccess(
        defaults: UserDefaults?,
        modelsDirectory: URL? = AppConstants.modelsDirectoryURL
    ) -> InstalledModelAccess? {
        #if os(macOS)
        if let externalURL = ExternalModelBookmarkStore.resolveURL(
            for: id,
            defaults: defaults
        ) {
            let access = InstalledModelAccess(url: externalURL, source: .external)
            if isValidInstallation(at: access.url) {
                return access
            }
        }
        #endif

        guard let modelsDirectory else { return nil }
        let appManagedURL = appManagedURL(in: modelsDirectory)
        guard isValidInstallation(at: appManagedURL) else { return nil }
        return InstalledModelAccess(url: appManagedURL, source: .appManaged)
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
            guard FileManager.default.fileExists(atPath: artifactURL.path) else { continue }
            let hasInvalidSize = Self.fileSize(at: artifactURL) != expectedByteCount
            let isJSON = artifactURL.pathExtension.lowercased() == "json"
            let hasInvalidJSON = isJSON && !Self.hasValidParakeetJSON(at: artifactURL)
            guard hasInvalidSize || hasInvalidJSON else { continue }
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

    private static func file(at url: URL, startsWith prefix: Data) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let leadingBytes = try? handle.read(upToCount: prefix.count) else { return false }
        return leadingBytes == prefix
    }

    private static func hasValidParakeetJSON(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return false
        }
        if url.lastPathComponent == ModelEngine.parakeetVocabularyFile {
            return (object as? [String: Any])?.isEmpty == false
        }
        if let dictionary = object as? [String: Any] {
            return !dictionary.isEmpty
        }
        if let array = object as? [Any] {
            return !array.isEmpty
        }
        return false
    }

    /// App-managed path for this model. External model locations must be used
    /// through `installedModelAccess(defaults:)` so their security scope remains
    /// active while the inference context reads them.
    public var localURL: URL? {
        guard let modelsDirectory = AppConstants.modelsDirectoryURL else { return nil }
        return appManagedURL(in: modelsDirectory)
    }

    private func appManagedURL(in modelsDirectory: URL) -> URL {
        if engine.isParakeet {
            let folderName = engine.parakeetRepoFolderName ?? fileName
            return modelsDirectory.appendingPathComponent(folderName, isDirectory: true)
        }
        return modelsDirectory.appendingPathComponent(fileName)
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
            trustedFileHeader: Data(hexString: "6c6d676799ca0000dc050000800100000600000004000000c0010000800100000600000004000000500000000100000050000000c900000000000000a4accb3c")!,
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin")!,
            isBundled: false
        ),
        WhisperModelInfo(
            id: "ggml-base",
            name: "Base",
            fileName: "ggml-base.bin",
            sizeLabel: "142 MB",
            downloadSizeBytes: 147_951_465,
            trustedFileHeader: Data(hexString: "6c6d676799ca0000dc050000000200000800000006000000c0010000000200000800000006000000500000000100000050000000c900000000000000a4accb3c")!,
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin")!,
            isBundled: false
        ),
        WhisperModelInfo(
            id: "ggml-small",
            name: "Small",
            fileName: "ggml-small.bin",
            sizeLabel: "466 MB",
            downloadSizeBytes: 487_601_967,
            trustedFileHeader: Data(hexString: "6c6d676799ca0000dc050000000300000c0000000c000000c0010000000300000c0000000c000000500000000100000050000000c900000000000000a4accb3c")!,
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin")!,
            isBundled: false
        ),
        WhisperModelInfo(
            id: "ggml-medium",
            name: "Medium",
            fileName: "ggml-medium.bin",
            sizeLabel: "1.5 GB",
            downloadSizeBytes: 1_533_763_059,
            trustedFileHeader: Data(hexString: "6c6d676799ca0000dc050000000400001000000018000000c0010000000400001000000018000000500000000100000050000000c900000000000000a4accb3c")!,
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin")!,
            isBundled: false
        ),
        WhisperModelInfo(
            id: "ggml-large-v3-turbo",
            name: "Large v3 Turbo",
            fileName: "ggml-large-v3-turbo.bin",
            sizeLabel: "1.6 GB",
            downloadSizeBytes: 1_624_555_275,
            trustedFileHeader: Data(hexString: "6c6d67679aca0000dc050000000500001400000020000000c0010000000500001400000004000000800000000100000080000000c90000000000008043bc4a3c")!,
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

private extension Data {
    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let nextIndex = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<nextIndex], radix: 16) else { return nil }
            bytes.append(byte)
            index = nextIndex
        }
        self.init(bytes)
    }
}
