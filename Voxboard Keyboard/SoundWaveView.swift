import SwiftUI

/// Compact waveform — white rectangular bars reacting to audio levels.
/// Square-cornered, no fill colour — matches brutal aesthetic.
struct SoundWaveView: View {
    /// Audio levels 0.0–1.0, one per bar.
    let levels: [Float]

    private let minFraction: CGFloat = 0.15
    private let maxHeight: CGFloat = 20
    private let barWidth: CGFloat  = 3
    private let barSpacing: CGFloat = 2

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                let fraction = max(minFraction, CGFloat(level))
                Rectangle()
                    .fill(Color.white.opacity(0.8))
                    .frame(width: barWidth, height: maxHeight * fraction)
                    .animation(.easeInOut(duration: 0.08), value: level)
            }
        }
        .frame(height: maxHeight)
    }
}
