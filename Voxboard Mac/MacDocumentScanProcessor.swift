import AppKit
import ImageIO
import PDFKit
import Vision

struct MacProcessedDocumentScan: Sendable {
    var pageImages: [Data]
    var pdfData: Data
    var extractedText: String?
}

enum MacDocumentScanProcessor {
    static func process(imageURLs: [URL]) async throws -> MacProcessedDocumentScan {
        let pageImages = try imageURLs.map { url in
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            return try Data(contentsOf: url)
        }
        let recognizedText = try await recognizeText(in: pageImages)
        let pdfData = try makePDF(from: pageImages)
        return MacProcessedDocumentScan(
            pageImages: pageImages,
            pdfData: pdfData,
            extractedText: recognizedText.isEmpty ? nil : recognizedText
        )
    }

    private static func recognizeText(in pages: [Data]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            var pageTexts: [String] = []
            for data in pages {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                let lines = (request.results ?? []).compactMap { observation in
                    observation.topCandidates(1).first?.string
                }
                if !lines.isEmpty {
                    pageTexts.append(lines.joined(separator: "\n"))
                }
            }
            return pageTexts.joined(separator: "\n\n")
        }.value
    }

    @MainActor
    private static func makePDF(from pages: [Data]) throws -> Data {
        let document = PDFDocument()
        var pageIndex = 0
        for data in pages {
            guard let image = NSImage(data: data),
                  let page = PDFPage(image: image) else { continue }
            document.insert(page, at: pageIndex)
            pageIndex += 1
        }
        guard pageIndex > 0, let data = document.dataRepresentation() else {
            throw MacDocumentScanError.noReadablePages
        }
        return data
    }
}

private enum MacDocumentScanError: Error, LocalizedError {
    case noReadablePages

    var errorDescription: String? {
        String(localized: "The selected scan images could not be read.")
    }
}
