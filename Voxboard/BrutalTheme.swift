import SwiftUI
import Combine

// MARK: - Design Tokens
// Matches imghost.isolated.tech brutal aesthetic:
// Pure black/white, monospaced font, square corners, 1px borders.

enum Brutal {

    // ── Colors ──────────────────────────────────────────────────────────────
    static let bg        = Color(red: 0,     green: 0,     blue: 0)       // #000000
    static let surface   = Color(red: 0.067, green: 0.067, blue: 0.067)   // #111111
    static let surface2  = Color(red: 0.1,   green: 0.1,   blue: 0.1)     // #1a1a1a
    static let border    = Color(white: 0.165)                             // #2a2a2a
    static let borderHi  = Color(white: 0.267)                             // #444444
    static let text      = Color.white
    static let muted     = Color(white: 0.72)                              // #B8B8B8 — readable secondary (~14:1)
    static let faint     = Color(white: 0.60)                              // #999999 — readable hint (≥7:1 on black)
    static let error     = Color(red: 1.0, green: 0.271, blue: 0.227)     // #FF453A

    // ── Fonts (all monospaced, Dynamic-Type-aware) ──────────────────────────
    // Semantic text-style overloads scale automatically with the user's
    // iOS Settings → Display & Brightness → Text Size preference.
    // `display` uses a fixed size (hero/status numbers already use
    // minimumScaleFactor and are large enough at any setting).

    /// Large decorative status words ("STANDBY.", "RECORDING."). Fixed size.
    static func display(_ size: CGFloat) -> Font {
        .system(size: size, weight: .heavy, design: .monospaced)
    }

    /// Section / overlay headings. Scales with Dynamic Type.
    static func heading(_ style: Font.TextStyle = .title3) -> Font {
        .system(style, design: .monospaced, weight: .bold)
    }

    /// Buttons, navigation titles, key labels. Scales with Dynamic Type.
    static func label(_ style: Font.TextStyle = .callout) -> Font {
        .system(style, design: .monospaced, weight: .semibold)
    }

    /// Body / transcript / description text. Scales with Dynamic Type.
    static func body(_ style: Font.TextStyle = .body) -> Font {
        .system(style, design: .monospaced, weight: .regular)
    }

    /// Metadata, badges, sub-labels. Scales with Dynamic Type.
    static func caption(_ style: Font.TextStyle = .footnote) -> Font {
        .system(style, design: .monospaced, weight: .regular)
    }
}

// MARK: - Button Style

/// Single parameterised button style — primary, secondary, or destructive.
struct BrutalButtonStyle: ButtonStyle {
    enum Variant { case primary, secondary, destructive }
    let variant: Variant

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Brutal.label())
            .foregroundColor(fg(configuration.isPressed))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(bg(configuration.isPressed))
            .overlay(Rectangle().stroke(border(configuration.isPressed), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }

    private func fg(_ p: Bool) -> Color {
        switch variant {
        case .primary:     return Brutal.bg
        case .secondary:   return p ? Brutal.muted : Brutal.text
        case .destructive: return Brutal.text
        }
    }
    private func bg(_ p: Bool) -> Color {
        switch variant {
        case .primary:     return p ? Color(white: 0.85) : Brutal.text
        case .secondary:   return p ? Brutal.surface : .clear
        case .destructive: return p ? Brutal.error.opacity(0.7) : Brutal.error
        }
    }
    private func border(_ p: Bool) -> Color {
        switch variant {
        case .primary:     return .clear
        case .secondary:   return p ? Brutal.borderHi : Brutal.border
        case .destructive: return .clear
        }
    }
}

// MARK: - Reusable Components

/// 1 px horizontal rule.
struct BrutalDivider: View {
    var body: some View {
        Rectangle().fill(Brutal.border).frame(height: 1)
    }
}

/// ■ STATUS square badge.
struct BrutalStatusBadge: View {
    let label: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 5) {
            Rectangle()
                .fill(isActive ? Brutal.text : Brutal.faint)
                .frame(width: 5, height: 5)
            Text(label.uppercased())
                .font(Brutal.caption())
                .foregroundColor(isActive ? Brutal.text : Brutal.faint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .overlay(Rectangle().stroke(isActive ? Brutal.borderHi : Brutal.border, lineWidth: 1))
    }
}

/// "01 / SECTION TITLE" cap label.
struct BrutalSectionLabel: View {
    let number: String
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Text(number)
                .font(Brutal.label())
                .foregroundColor(Brutal.faint)
            Rectangle().fill(Brutal.border).frame(width: 16, height: 1)
            Text(title.uppercased())
                .font(Brutal.label())
                .foregroundColor(Brutal.faint)
        }
    }
}

// MARK: - Background Grid

/// Subtle crosshatch grid — like imghost's hero section.
struct BrutalGridBackground: View {
    var spacing: CGFloat = 52
    var lineOpacity: Double = 0.13

    var body: some View {
        Canvas { ctx, size in
            let shading = GraphicsContext.Shading.color(Color(white: 1, opacity: lineOpacity))
            var x: CGFloat = 0
            while x <= size.width {
                let p = Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) }
                ctx.stroke(p, with: shading, lineWidth: 0.5)
                x += spacing
            }
            var y: CGFloat = 0
            while y <= size.height {
                let p = Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) }
                ctx.stroke(p, with: shading, lineWidth: 0.5)
                y += spacing
            }
        }
        .mask(
            LinearGradient(
                colors: [.black.opacity(0.8), .black.opacity(0.4), .clear],
                startPoint: .top, endPoint: .bottom
            )
        )
    }
}

// MARK: - Waveform & Dots

/// Animated bars for the standby-listening state.
struct IdleWaveformView: View {
    private let barCount = 9

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<barCount, id: \.self) { i in
                    let phase = t * 2.0 + Double(i) * 0.55
                    let h = (sin(phase) + 1) / 2 * 22 + 5
                    Rectangle()
                        .fill(Brutal.text.opacity(0.45))
                        .frame(width: 3, height: h)
                }
            }
            .frame(height: 28)
        }
    }
}

/// "TRANSCRIBING..." with cycling dots.
struct TranscribingDotsView: View {
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()
    @State private var count = 0

    var body: some View {
        Text("TRANSCRIBING" + String(repeating: ".", count: (count % 3) + 1))
            .font(Brutal.display(40))
            .foregroundColor(Brutal.text)
            .lineLimit(1)
            .minimumScaleFactor(0.35)
            .onReceive(timer) { _ in count += 1 }
    }
}
