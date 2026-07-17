import PencilKit
import SwiftUI
import UIKit
import Vision
import VisionKit

struct CaptureCameraPicker: UIViewControllerRepresentable {
    var onCapture: (Data) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CaptureCameraPicker
        init(parent: CaptureCameraPicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let image = info[.originalImage] as? UIImage,
                  let data = image.jpegData(compressionQuality: 0.9) else {
                parent.onCancel()
                return
            }
            parent.onCapture(data)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCancel()
        }
    }
}

struct CaptureDocumentScanner: UIViewControllerRepresentable {
    var onScan: ([Data]) -> Void
    var onCancel: () -> Void
    var onError: (Error) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let scanner = VNDocumentCameraViewController()
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: CaptureDocumentScanner
        init(parent: CaptureDocumentScanner) { self.parent = parent }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            let pages = (0..<scan.pageCount).compactMap {
                scan.imageOfPage(at: $0).jpegData(compressionQuality: 0.9)
            }
            parent.onScan(pages)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.onCancel()
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            parent.onError(error)
        }
    }
}

struct ProcessedDocumentScan: Sendable {
    var pageImages: [Data]
    var pdfData: Data
    var extractedText: String?
}

enum DocumentScanProcessor {
    static func process(pageImages: [Data]) async throws -> ProcessedDocumentScan {
        let text = try await recognizeText(in: pageImages)
        let pdf = try makePDF(from: pageImages)
        return ProcessedDocumentScan(
            pageImages: pageImages,
            pdfData: pdf,
            extractedText: text.isEmpty ? nil : text
        )
    }

    private static func recognizeText(in pages: [Data]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            var pageTexts: [String] = []
            for data in pages {
                guard let image = UIImage(data: data)?.cgImage else { continue }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                try VNImageRequestHandler(cgImage: image).perform([request])
                let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                if !lines.isEmpty { pageTexts.append(lines.joined(separator: "\n")) }
            }
            return pageTexts.joined(separator: "\n\n")
        }.value
    }

    @MainActor
    private static func makePDF(from pages: [Data]) throws -> Data {
        let images = pages.compactMap(UIImage.init(data:))
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        return renderer.pdfData { context in
            for image in images {
                context.beginPage()
                let inset = pageRect.insetBy(dx: 24, dy: 24)
                let scale = min(inset.width / image.size.width, inset.height / image.size.height)
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                let origin = CGPoint(x: inset.midX - size.width / 2, y: inset.midY - size.height / 2)
                image.draw(in: CGRect(origin: origin, size: size))
            }
        }
    }
}

struct CaptureSketchEditor: View {
    var onSave: (Data, Data) -> Void
    var onCancel: () -> Void
    @State private var drawing = PKDrawing()

    var body: some View {
        NavigationStack {
            PencilCanvas(drawing: $drawing)
                .background(Color.white)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Sketch")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") {
                            let bounds = drawing.bounds.isEmpty
                                ? CGRect(x: 0, y: 0, width: 1024, height: 768)
                                : drawing.bounds.insetBy(dx: -24, dy: -24)
                            let preview = drawing.image(from: bounds, scale: 2)
                            guard let png = preview.pngData() else { return }
                            onSave(drawing.dataRepresentation(), png)
                        }
                        .disabled(drawing.strokes.isEmpty)
                    }
                }
        }
    }
}

private struct PencilCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing

    func makeCoordinator() -> Coordinator { Coordinator(drawing: $drawing) }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.delegate = context.coordinator
        canvas.drawing = drawing
        canvas.drawingPolicy = .anyInput
        canvas.backgroundColor = .white
        canvas.tool = PKInkingTool(.pen, color: .black, width: 4)
        DispatchQueue.main.async {
            let picker = PKToolPicker()
            picker.setVisible(true, forFirstResponder: canvas)
            picker.addObserver(canvas)
            canvas.becomeFirstResponder()
            context.coordinator.toolPicker = picker
        }
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        if canvas.drawing != drawing { canvas.drawing = drawing }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        @Binding var drawing: PKDrawing
        var toolPicker: PKToolPicker?
        init(drawing: Binding<PKDrawing>) { _drawing = drawing }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) { drawing = canvasView.drawing }
    }
}
