import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import VoxCoreGenerated

private let maximumChunkBytes = 1_048_576
private var failureStage = "startup"

private func canonicalJSONString(_ value: String) throws -> String {
    let wrapped = try JSONSerialization.data(
        withJSONObject: [value],
        options: [.withoutEscapingSlashes]
    )
    guard wrapped.count >= 2 else {
        throw NSError(domain: "VoxboardM2MaterializationEvidence", code: 65)
    }
    return String(decoding: wrapped.dropFirst().dropLast(), as: UTF8.self)
}

private func canonicalJSONFragment(_ value: Any, depth: Int) throws -> String {
    let indentation = String(repeating: " ", count: depth * 2)
    let childIndentation = indentation + "  "
    if value is NSNull { return "null" }
    if let string = value as? String { return try canonicalJSONString(string) }
    if let number = value as? NSNumber {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }
        guard CFNumberIsFloatType(number) == false else {
            throw NSError(domain: "VoxboardM2MaterializationEvidence", code: 66)
        }
        return number.stringValue
    }
    if let array = value as? [Any] {
        guard !array.isEmpty else { return "[]" }
        let values = try array.map {
            childIndentation + (try canonicalJSONFragment($0, depth: depth + 1))
        }
        return "[\n" + values.joined(separator: ",\n") + "\n" + indentation + "]"
    }
    if let object = value as? [String: Any] {
        guard !object.isEmpty else { return "{}" }
        let values = try object.keys.sorted().map { key in
            let encodedKey = try canonicalJSONString(key)
            let encodedValue = try canonicalJSONFragment(object[key]!, depth: depth + 1)
            return "\(childIndentation)\(encodedKey): \(encodedValue)"
        }
        return "{\n" + values.joined(separator: ",\n") + "\n" + indentation + "}"
    }
    throw NSError(domain: "VoxboardM2MaterializationEvidence", code: 67)
}

private func canonicalJSON(_ value: Any) throws -> Data {
    Data((try canonicalJSONFragment(value, depth: 0) + "\n").utf8)
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func residentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    precondition(result == KERN_SUCCESS, "resident-size sampling failed")
    return UInt64(info.resident_size)
}

private final class RSSSampler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "md.vox.m2-rss-sampler")
    private let start: UInt64
    private var timer: DispatchSourceTimer?
    private var values: [[String: Any]] = []
    let baseline: UInt64

    init(start: UInt64) {
        self.start = start
        baseline = residentBytes()
        values = [["elapsedNanoseconds": 0, "residentBytes": baseline]]
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + .milliseconds(2), repeating: .milliseconds(2))
        source.setEventHandler { [weak self] in self?.appendSample() }
        timer = source
        source.resume()
    }

    private func appendSample() {
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        guard (values.last?["elapsedNanoseconds"] as? UInt64) != elapsed else { return }
        values.append(["elapsedNanoseconds": elapsed, "residentBytes": residentBytes()])
    }

    func sample() {
        queue.sync { appendSample() }
    }

    func finish(duration: UInt64) -> [[String: Any]] {
        queue.sync {
            timer?.cancel()
            timer = nil
            values.removeAll { ($0["elapsedNanoseconds"] as? UInt64 ?? 0) >= duration && ($0["elapsedNanoseconds"] as? UInt64 ?? 0) != 0 }
            values.append(["elapsedNanoseconds": duration, "residentBytes": residentBytes()])
            return values
        }
    }
}

private func preparation() throws -> (Data, [String: Any]) {
    let value: [String: Any] = [
        "calendar": "gregorian",
        "captureSource": "app",
        "contractVersion": 1,
        "createdAtEpochMilliseconds": 1_700_000_000_000 as Int64,
        "invocation": ["locationOutcome": "notRequested", "originRecordingID": NSNull(), "sequence": 1],
        "locale": "en-US",
        "operation": "newNote",
        "payloads": [["id": "22222222-2222-4222-8222-222222222222", "kind": "text", "text": "M2 synthetic materialization"]],
        "pins": ["coreVersion": "0.1.0-alpha.1", "modelProfileID": NSNull(), "modelRevision": NSNull(), "profileID": "apple-parity-v1", "profileVersion": 1, "rendererRevision": "swift-legacy-m0"],
        "preset": [
            "destinationPolicy": ["capabilityClass": "userVault", "capabilityReference": "synthetic", "expectedCaseSensitivity": "sensitive"],
            "id": "33333333-3333-4333-8333-333333333333",
            "metadataPolicy": ["finalNewline": true, "frontmatterMode": "merge", "lineEnding": "lf", "orderedFields": [], "templatePolicy": "frozenObservation"],
            "retryMarkerPolicy": "none",
            "revision": 1,
            "routePolicy": ["attachmentFolder": [], "collisionPolicy": "deterministicSuffix", "extensionPolicy": "markdownDotMd", "logicalFolder": ["Inbox"], "noteNameTemplate": "m2-evidence"],
            "snapshotHash": String(repeating: "a", count: 64),
            "templateFreezePoint": "firstPreparation",
        ],
        "requestID": "11111111-1111-4111-8111-111111111111",
        "timezone": "UTC",
    ]
    return (try canonicalJSON(value), value)
}

private func main() throws {
    guard CommandLine.arguments.count == 5 else {
        throw NSError(domain: "VoxboardM2MaterializationEvidence", code: 64)
    }
    failureStage = "control"
    let benchmarkControlURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let inputURL = URL(fileURLWithPath: CommandLine.arguments[2])
    let outputURL = URL(fileURLWithPath: CommandLine.arguments[3])
    let reportURL = URL(fileURLWithPath: CommandLine.arguments[4])
    let benchmark = try JSONSerialization.jsonObject(with: Data(contentsOf: benchmarkControlURL)) as! [String: Any]
    let expectedBytes = benchmark["streamBytes"] as! Int
    let inputData = try Data(contentsOf: inputURL, options: [.mappedIfSafe])
    guard inputData.count == expectedBytes else { throw NSError(domain: "VoxboardM2MaterializationEvidence", code: 2) }

    let inputHash = sha256(inputData)
    failureStage = "prepare"
    let (preparationData, preparationValue) = try preparation()
    let requirementsData = try corePrepare(preparationJson: preparationData)
    let requirements = try JSONSerialization.jsonObject(with: requirementsData) as! [String: Any]
    let required = requirements["observations"] as! [[String: Any]]
    let emptyPathsData = try canonicalJSON([])
    let materialization: [String: Any] = [
        "calendar": preparationValue["calendar"]!, "captureSource": preparationValue["captureSource"]!, "contractVersion": 1,
        "controlByteCount": 1, "createdAtEpochMilliseconds": preparationValue["createdAtEpochMilliseconds"]!,
        "invocation": preparationValue["invocation"]!, "locale": preparationValue["locale"]!,
        "observations": [
            ["kind": "candidateOccupancy", "logicalPaths": [], "observationID": required[0]["id"]!, "orderedSetHash": sha256(emptyPathsData), "status": "present"],
            ["byteStreamID": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "kind": "frozenTemplate", "length": expectedBytes, "observationID": required[1]["id"]!, "sha256": inputHash, "status": "present"],
        ],
        "operation": preparationValue["operation"]!, "payloads": preparationValue["payloads"]!, "pins": preparationValue["pins"]!,
        "preparationRevision": 1, "preset": preparationValue["preset"]!, "requestID": preparationValue["requestID"]!,
        "session": ["inputOrdering": "observation-list-then-sequence", "maximumAggregateObservationBytes": 268_435_456, "maximumChunkBytes": maximumChunkBytes, "singleFinalize": true, "singleSeal": true],
        "snapshotHash": requirements["snapshotHash"]!, "timezone": preparationValue["timezone"]!,
    ]
    let materializationData = try canonicalJSON(materialization)

    let start = DispatchTime.now().uptimeNanoseconds
    let sampler = RSSSampler(start: start)
    failureStage = "startSession"
    let session = try coreStartMaterialization(controlJson: materializationData)
    sampler.sample()
    var ingress: [[String: Any]] = []
    failureStage = "pushObservation"
    for sequence in 0..<((inputData.count + maximumChunkBytes - 1) / maximumChunkBytes) {
        let lower = sequence * maximumChunkBytes
        let upper = min(inputData.count, lower + maximumChunkBytes)
        let chunk = inputData.subdata(in: lower..<upper)
        try session.pushObservation(streamId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", sequence: UInt32(sequence), bytes: chunk, eof: upper == inputData.count)
        sampler.sample()
        ingress.append(["sequence": sequence, "bytes": chunk.count, "sha256": sha256(chunk)])
    }
    failureStage = "seal"
    let descriptors = try session.seal()
    sampler.sample()
    guard descriptors.artifacts.count == 1 else { throw NSError(domain: "VoxboardM2MaterializationEvidence", code: 3) }
    let descriptor = descriptors.artifacts[0]
    var output = Data()
    var drain: [[String: Any]] = []
    var sequence: UInt32 = 0
    failureStage = "drain"
    while true {
        let chunk = try session.drain(artifactId: descriptor.artifactId, sequence: sequence, maximumBytes: UInt64(maximumChunkBytes))
        output.append(chunk.bytes)
        sampler.sample()
        drain.append(["sequence": Int(sequence), "bytes": chunk.bytes.count, "sha256": chunk.chunkSha256])
        if chunk.eof { break }
        sequence += 1
    }
    let drained = try canonicalJSON([
        "artifacts": [["artifactID": descriptor.artifactId, "length": descriptor.length, "resultSHA256": descriptor.resultSha256, "streamID": descriptor.streamId]],
        "kind": "drainedArtifactHashes", "requestID": descriptors.requestId,
    ])
    failureStage = "finalize"
    _ = try session.finalize(drainedHashesJson: drained)
    sampler.sample()
    let duration = max(1, DispatchTime.now().uptimeNanoseconds - start)
    let samples = sampler.finish(duration: duration)
    failureStage = "writeEvidence"
    try output.write(to: outputURL, options: .atomic)
    let resident = samples.compactMap { $0["residentBytes"] as? UInt64 }
    let peak = resident.max() ?? sampler.baseline
    let report: [String: Any] = [
        "drainChunks": drain,
        "durationNanoseconds": duration,
        "ingressChunks": ingress,
        "outputBytes": output.count,
        "outputSha256": sha256(output),
        "rss": [
            "additionalBytes": peak > sampler.baseline ? peak - sampler.baseline : 0,
            "baselineBytes": sampler.baseline,
            "baselineDefinition": "resident bytes immediately before opening the measured production session",
            "method": "macosMachTaskResidentSizeSampled",
            "peakBytes": peak,
            "sampleIntervalNanoseconds": 10_000_000,
            "samples": samples,
        ],
        "verifiedDrain": ["descriptorOutputBytes": descriptor.length, "descriptorOutputSha256": descriptor.resultSha256, "terminalState": "completed"],
    ]
    try canonicalJSON(report).write(to: reportURL, options: .atomic)
}

do {
    try main()
} catch let error as VoxCoreError {
    fputs("M2 materialization host failed at privacy-safe stage: \(failureStage), code: \(String(describing: error))\n", stderr)
    exit(1)
} catch {
    fputs("M2 materialization host failed at privacy-safe stage: \(failureStage)\n", stderr)
    exit(1)
}
