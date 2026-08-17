import Foundation
import VoxCoreGenerated
import VoxboardCaptureCore

public struct VoxCoreRustBuildInfo: Equatable, Sendable {
    public let coreAPIVersion: UInt32
    public let coreVersion: String
    public let sourceRevision: String
    public let buildConfiguration: String
    public let toolchainManifestSHA256: String
    public let supportedOperations: [String]
    public let supportedProfileIDs: [String]
}

public struct VoxCoreRustReadiness: Equatable, Sendable {
    public let status: String
    public let sessionPermitted: Bool
    public let mismatchCodes: [String]
}

public struct VoxCoreRustArtifactDescriptor: Equatable, Sendable {
    public let artifactID: String
    public let operationID: String
    public let streamID: String
    public let commitSequence: UInt32
    public let kind: String
    public let mediaType: String
    public let length: UInt64
    public let resultSHA256: String
    public let receiptKind: String
}

public struct VoxCoreRustPreparedChunk: Equatable, Sendable {
    public let artifactID: String
    public let streamID: String
    public let sequence: UInt32
    public let bytes: Data
    public let byteCount: UInt64
    public let chunkSHA256: String
    public let eof: Bool
}

/// Handwritten owned-value wrapper around committed UniFFI-generated Swift. It exposes
/// no native storage handles, callbacks, paths, or persistence authority.
public struct VoxCoreRustClient: Sendable {
    public init() {}

    public func buildInfo() throws -> VoxCoreRustBuildInfo {
        let value = try VoxCoreGenerated.coreBuildInfo()
        return VoxCoreRustBuildInfo(
            coreAPIVersion: value.coreApiVersion,
            coreVersion: value.coreVersion,
            sourceRevision: value.sourceRevision,
            buildConfiguration: value.buildConfiguration,
            toolchainManifestSHA256: value.toolchainManifestSha256,
            supportedOperations: value.supportedOperations,
            supportedProfileIDs: value.supportedProfileIds
        )
    }

    public func readiness(expectedVersionsJSON: Data) throws -> VoxCoreRustReadiness {
        let value = try VoxCoreGenerated.coreReadiness(expectedVersionsJson: expectedVersionsJSON)
        return VoxCoreRustReadiness(
            status: value.status,
            sessionPermitted: value.sessionPermitted,
            mismatchCodes: value.mismatchCodes
        )
    }

    public func prepare(preparationJSON: Data) throws -> Data {
        try VoxCoreGenerated.corePrepare(preparationJson: preparationJSON)
    }

    public func startMaterialization(controlJSON: Data) throws -> VoxCoreRustSession {
        try VoxCoreRustSession(
            generated: VoxCoreGenerated.coreStartMaterialization(controlJson: controlJSON)
        )
    }
}

public final class VoxCoreRustSession: @unchecked Sendable {
    private let generated: CoreMaterializationSession

    fileprivate init(generated: CoreMaterializationSession) {
        self.generated = generated
    }

    public func pushObservation(
        streamID: String,
        sequence: UInt32,
        bytes: Data,
        eof: Bool
    ) throws {
        try generated.pushObservation(
            streamId: streamID,
            sequence: sequence,
            bytes: bytes,
            eof: eof
        )
    }

    public func seal() throws -> [VoxCoreRustArtifactDescriptor] {
        try generated.seal().artifacts.map { value in
            VoxCoreRustArtifactDescriptor(
                artifactID: value.artifactId,
                operationID: value.operationId,
                streamID: value.streamId,
                commitSequence: value.commitSequence,
                kind: value.kind,
                mediaType: value.mediaType,
                length: value.length,
                resultSHA256: value.resultSha256,
                receiptKind: value.receiptKind
            )
        }
    }

    public func drain(
        artifactID: String,
        sequence: UInt32,
        maximumBytes: UInt64
    ) throws -> VoxCoreRustPreparedChunk {
        let value = try generated.drain(
            artifactId: artifactID,
            sequence: sequence,
            maximumBytes: maximumBytes
        )
        return VoxCoreRustPreparedChunk(
            artifactID: value.artifactId,
            streamID: value.streamId,
            sequence: value.sequence,
            bytes: value.bytes,
            byteCount: value.byteCount,
            chunkSHA256: value.chunkSha256,
            eof: value.eof
        )
    }

    public func finalize(drainedHashesJSON: Data) throws -> Data {
        try generated.finalize(drainedHashesJson: drainedHashesJSON)
    }

    public func cancel() {
        generated.cancel()
    }
}

/// Operation-scoped adapter used by Apple shadow hosts after they have frozen native
/// observations. The comparison closure can call `VoxCoreRustClient`; only equality
/// facts return to CaptureCore, so no user content or logical path enters diagnostics.
public struct VoxCoreRustComparisonAdapter: CaptureCoreComparing {
    public typealias Comparison = @Sendable (
        CaptureCoreAdmittedInput,
        VoxCoreRustClient
    ) async throws -> CaptureCoreComparison

    private let operation: Comparison

    public init(operation: @escaping Comparison) {
        self.operation = operation
    }

    public func compare(_ input: CaptureCoreAdmittedInput) async throws -> CaptureCoreComparison {
        try await operation(input, VoxCoreRustClient())
    }
}
