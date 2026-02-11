import SwiftUI

/// A compact sound wave animation that reacts to audio levels.
/// Shows a row of vertical bars that grow/shrink based on the provided levels array.
struct SoundWaveView: View {
    /// Audio levels (0.0–1.0), one per bar. Typically 5–7 values.
    let levels: [Float]

    /// Minimum bar height as a fraction of maxHeight (so bars are always visible).
    private let minBarFraction: CGFloat = 0.15

    /// Total height of the view.
    private let maxHeight: CGFloat = 20

    /// Bar width.
    private let barWidth: CGFloat = 3

    /// Spacing between bars.
    private let barSpacing: CGFloat = 2

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                let fraction = max(minBarFraction, CGFloat(level))
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(Color.red)
                    .frame(width: barWidth, height: maxHeight * fraction)
                    .animation(.easeInOut(duration: 0.1), value: level)
            }
        }
        .frame(height: maxHeight)
    }
}
