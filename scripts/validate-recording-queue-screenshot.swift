#!/usr/bin/env swift

import Foundation
import ImageIO
import Vision

struct ScreenshotExpectation {
    let required: [String]
    let forbidden: [String]
}

let expectations: [String: ScreenshotExpectation] = [
    "ios-failed": .init(
        required: ["Recording Queue", "Recovered Recording", "Needs attention", "Choose Preset", "Share Audio", "Keep Audio", "Delete"],
        forbidden: ["What's new in Vox.md"]
    ),
    "ios-failed-accessibility": .init(
        required: ["Recording Queue", "Needs attention", "Choose Preset", "Share Audio", "Keep Audio"],
        forbidden: ["What's new in Vox.md"]
    ),
    "ios-queued": .init(
        required: ["Recording Queue", "Recovered Recording", "Queued", "Process Now", "Share Audio", "Keep Audio", "Delete"],
        forbidden: ["What's new in Vox.md"]
    ),
    "ios-copy-ready": .init(
        required: ["Recording Queue", "Clipboard Transcription", "Ready to copy", "Copy", "Share Audio", "Keep Audio", "Delete"],
        forbidden: ["What's new in Vox.md"]
    ),
    "mac-failed": .init(
        required: ["Recovered Recording", "Needs attention", "Choose Preset", "Reveal", "Keep Audio", "Delete"],
        forbidden: []
    ),
    "mac-queued": .init(
        required: ["Recovered Recording", "Queued", "Process Now", "Reveal", "Keep Audio", "Delete"],
        forbidden: []
    ),
    "mac-copy-ready": .init(
        required: ["Clipboard Transcription", "Ready to copy", "Copy", "Reveal", "Keep Audio", "Delete"],
        forbidden: []
    ),
]

func normalized(_ value: String) -> String {
    value
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        .replacingOccurrences(of: "[^a-z0-9]+", with: "", options: .regularExpression)
}

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: validate-recording-queue-screenshot.swift IMAGE STATE\n", stderr)
    exit(2)
}
let imageURL = URL(fileURLWithPath: CommandLine.arguments[1])
let state = CommandLine.arguments[2]
guard let expectation = expectations[state] else {
    fputs("Unknown recording queue screenshot state: \(state)\n", stderr)
    exit(2)
}
guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fputs("Could not decode screenshot: \(imageURL.path)\n", stderr)
    exit(1)
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = true
let handler = VNImageRequestHandler(cgImage: image)
do {
    try handler.perform([request])
} catch {
    fputs("Vision OCR failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
let recognized = (request.results ?? []).compactMap {
    $0.topCandidates(1).first?.string
}.joined(separator: " ")
let comparable = normalized(recognized)
let missing = expectation.required.filter { !comparable.contains(normalized($0)) }
let forbidden = expectation.forbidden.filter { comparable.contains(normalized($0)) }
if !missing.isEmpty || !forbidden.isEmpty {
    fputs("Screenshot semantic validation failed for \(state).\n", stderr)
    if !missing.isEmpty { fputs("Missing: \(missing.joined(separator: ", "))\n", stderr) }
    if !forbidden.isEmpty { fputs("Forbidden: \(forbidden.joined(separator: ", "))\n", stderr) }
    fputs("Recognized text: \(recognized)\n", stderr)
    exit(1)
}
print("Recording Queue screenshot semantics passed for \(state).")
