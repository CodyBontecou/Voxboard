import SwiftUI

/// Compact waveform — white rectangular bars reacting to audio levels.
/// Square-cornered, no fill colour — matches brutal aesthetic.
struct SoundWaveView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Audio levels 0.0–1.0, one per bar.
    let levels: [Float]

    private let minFraction: CGFloat = 0.15
    private let maxHeight: CGFloat = 20
    private let barWidth: CGFloat  = 3
    private let barSpacing: CGFloat = 2
    private let reducedMotionLevels: [CGFloat] = [0.35, 0.6, 0.8, 0.5, 0.7, 0.4, 0.55, 0.3]

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(Array(displayLevels.enumerated()), id: \.offset) { _, fraction in
                Rectangle()
                    .fill(Color.white.opacity(0.8))
                    .frame(width: barWidth, height: maxHeight * fraction)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.08), value: fraction)
            }
        }
        .frame(height: maxHeight)
        .accessibilityLabel(Text("Recording audio level"))
    }

    private var displayLevels: [CGFloat] {
        if reduceMotion {
            return reducedMotionLevels
        }

        return levels.map { max(minFraction, CGFloat($0)) }
    }
}
