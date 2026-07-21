import AppKit
import SwiftUI

private struct MacSketchPoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double

    init(_ point: CGPoint) {
        x = point.x
        y = point.y
    }

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

private struct MacSketchDocument: Codable, Sendable {
    var canvasWidth: Double
    var canvasHeight: Double
    var strokes: [[MacSketchPoint]]
}

struct MacSketchEditor: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (Data, Data) -> Void

    @State private var strokes: [[MacSketchPoint]] = []
    @State private var activeStroke: [MacSketchPoint] = []
    @State private var canvasSize = CGSize(width: 900, height: 560)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sketch")
                        .font(Geist.heading(.title2))
                    Text("Draw with a mouse, trackpad, or connected tablet.")
                        .font(Geist.caption())
                        .foregroundStyle(Geist.muted)
                }
                Spacer()
                Button("Clear", role: .destructive) {
                    strokes.removeAll()
                    activeStroke.removeAll()
                }
                .disabled(strokes.isEmpty && activeStroke.isEmpty)
                Button("Cancel") { dismiss() }
                Button("Add to Capture") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(strokes.isEmpty && activeStroke.isEmpty)
                    .accessibilityIdentifier("mac_capture_sketch_add")
            }
            .padding(Geist.Spacing.four)
            .background(Geist.Palette.background100)

            GeistDivider()

            GeometryReader { geometry in
                MacSketchCanvas(strokes: strokes, activeStroke: activeStroke)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                activeStroke.append(MacSketchPoint(value.location))
                            }
                            .onEnded { _ in
                                if !activeStroke.isEmpty {
                                    strokes.append(activeStroke)
                                }
                                activeStroke.removeAll()
                            }
                    )
                    .onAppear { canvasSize = geometry.size }
                    .onChange(of: geometry.size) { _, size in canvasSize = size }
            }
            .background(Color.white)
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    @MainActor
    private func save() {
        var finished = strokes
        if !activeStroke.isEmpty { finished.append(activeStroke) }
        guard !finished.isEmpty else { return }

        let document = MacSketchDocument(
            canvasWidth: canvasSize.width,
            canvasHeight: canvasSize.height,
            strokes: finished
        )
        guard let drawingData = try? JSONEncoder().encode(document) else { return }

        let renderSize = CGSize(
            width: max(1, canvasSize.width),
            height: max(1, canvasSize.height)
        )
        let renderer = ImageRenderer(
            content: MacSketchCanvas(strokes: finished, activeStroke: [])
                .frame(width: renderSize.width, height: renderSize.height)
        )
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }

        onSave(drawingData, png)
        dismiss()
    }
}

private struct MacSketchCanvas: View {
    let strokes: [[MacSketchPoint]]
    let activeStroke: [MacSketchPoint]

    var body: some View {
        Canvas { context, size in
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(.white)
            )
            for stroke in strokes + (activeStroke.isEmpty ? [] : [activeStroke]) {
                guard let first = stroke.first else { continue }
                var path = Path()
                path.move(to: first.cgPoint)
                for point in stroke.dropFirst() {
                    path.addLine(to: point.cgPoint)
                }
                if stroke.count == 1 {
                    path.addEllipse(in: CGRect(
                        x: first.x - 2,
                        y: first.y - 2,
                        width: 4,
                        height: 4
                    ))
                }
                context.stroke(
                    path,
                    with: .color(.black),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
                )
            }
        }
        .background(Color.white)
    }
}
