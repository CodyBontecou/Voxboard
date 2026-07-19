import SwiftUI
import Combine
import CoreText

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Geist design system

/// The app's UI source of truth is vendored in `docs/geist/design.md` and
/// `docs/geist/design.dark.md`. Semantic aliases below only point at values
/// defined by those documents; no product-specific colors are introduced.
enum Geist {
    enum Spacing {
        static let one: CGFloat = 4
        static let two: CGFloat = 8
        static let three: CGFloat = 12
        static let four: CGFloat = 16
        static let six: CGFloat = 24
        static let eight: CGFloat = 32
        static let ten: CGFloat = 40
        static let sixteen: CGFloat = 64
        static let twentyFour: CGFloat = 96
    }

    enum Radius {
        static let small: CGFloat = 6
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let full: CGFloat = 9_999
    }

    enum ControlHeight {
        static let small: CGFloat = 32
        static let medium: CGFloat = 40
        static let large: CGFloat = 48
    }

    enum Palette {
        // Shared with the keyboard's opaque backdrop for a seamless transition.
        static let background100 = adaptive("#e2e4e8", "#1a1a1c")
        static let background200 = adaptive("#e2e4e8", "#1a1a1c")

        static let gray100 = adaptive("#f2f2f2", "#1a1a1a")
        static let gray200 = adaptive("#ebebeb", "#1f1f1f")
        static let gray300 = adaptive("#e6e6e6", "#292929")
        static let gray400 = adaptive("#eaeaea", "#2e2e2e")
        static let gray500 = adaptive("#c9c9c9", "#454545")
        static let gray600 = adaptive("#a8a8a8", "#878787")
        static let gray700 = adaptive("#8f8f8f", "#8f8f8f")
        static let gray800 = adaptive("#7d7d7d", "#7d7d7d")
        static let gray900 = adaptive("#4d4d4d", "#a0a0a0")
        static let gray1000 = adaptive("#171717", "#ededed")

        static let grayAlpha100 = adaptive("#0000000d", "#ffffff12")
        static let grayAlpha200 = adaptive("#00000015", "#ffffff17")
        static let grayAlpha300 = adaptive("#0000001a", "#ffffff21")
        static let grayAlpha400 = adaptive("#00000014", "#ffffff24")
        static let grayAlpha500 = adaptive("#00000036", "#ffffff3d")
        static let grayAlpha600 = adaptive("#0000003d", "#ffffff82")
        static let grayAlpha700 = adaptive("#00000070", "#ffffff8a")
        static let grayAlpha800 = adaptive("#00000082", "#ffffff78")
        static let grayAlpha900 = adaptive("#000000b3", "#ffffff9c")
        static let grayAlpha1000 = adaptive("#000000e8", "#ffffffeb")

        static let blue100 = adaptive("#f0f7ff", "#06193a")
        static let blue200 = adaptive("#e9f4ff", "#022248")
        static let blue300 = adaptive("#dfefff", "#002f62")
        static let blue400 = adaptive("#cae7ff", "#003674")
        static let blue500 = adaptive("#94ccff", "#00418b")
        static let blue600 = adaptive("#48aeff", "#0090ff")
        static let blue700 = adaptive("#006bff", "#006efe")
        static let blue800 = adaptive("#0059ec", "#005be7")
        static let blue900 = adaptive("#005ff2", "#47a8ff")
        static let blue1000 = adaptive("#002359", "#eaf6ff")

        static let red100 = adaptive("#ffeeef", "#330a11")
        static let red200 = adaptive("#ffe8ea", "#440d13")
        static let red300 = adaptive("#ffe3e4", "#5d0e17")
        static let red400 = adaptive("#ffd7d6", "#6f101b")
        static let red500 = adaptive("#ffb1b3", "#88151f")
        static let red600 = adaptive("#ff676d", "#f32e40")
        static let red700 = adaptive("#fc0035", "#f13242")
        static let red800 = adaptive("#ea001d", "#e2162a")
        static let red900 = adaptive("#d8001b", "#ff565f")
        static let red1000 = adaptive("#47000c", "#ffe9ed")

        static let amber100 = adaptive("#fff6de", "#2a1700")
        static let amber700 = adaptive("#ffae00", "#ffae00")
        static let amber900 = adaptive("#aa4d00", "#ff9300")
        static let amber1000 = adaptive("#561900", "#fff3d5")

        static let green100 = adaptive("#ecfdec", "#002608")
        static let green700 = adaptive("#28a948", "#00ac3a")
        static let green900 = adaptive("#107d32", "#00ca50")
        static let green1000 = adaptive("#003a00", "#d8ffe4")
    }

    // Semantic roles from the documented scale intent.
    static let bg = Palette.background100
    static let surface = Palette.background100
    static let surface2 = Palette.background200
    static let border = Palette.grayAlpha400
    static let borderHi = Palette.grayAlpha500
    static let text = Palette.gray1000
    static let muted = Palette.gray900
    static let faint = Palette.gray700
    static let error = Palette.red900
    static let focus = Palette.blue700
    static let success = Palette.blue900

    // MARK: Typography tokens

    static func display(_ size: CGFloat) -> Font {
        .custom("Geist-SemiBold", fixedSize: size)
    }

    static func heading(_ style: Font.TextStyle = .title3) -> Font {
        .custom("Geist-SemiBold", size: headingSize(style), relativeTo: style)
    }

    static func label(_ style: Font.TextStyle = .callout) -> Font {
        .custom("Geist-Medium", size: labelSize(style), relativeTo: style)
    }

    static func body(_ style: Font.TextStyle = .body) -> Font {
        .custom("Geist-Regular", size: bodySize(style), relativeTo: style)
    }

    static func caption(_ style: Font.TextStyle = .footnote) -> Font {
        .custom("Geist-Regular", size: captionSize(style), relativeTo: style)
    }

    static func mono(_ style: Font.TextStyle = .footnote, medium: Bool = false) -> Font {
        .custom(medium ? "GeistMono-Medium" : "GeistMono-Regular", size: captionSize(style), relativeTo: style)
    }

    static func mono(size: CGFloat, relativeTo style: Font.TextStyle = .body, medium: Bool = false) -> Font {
        .custom(medium ? "GeistMono-Medium" : "GeistMono-Regular", size: size, relativeTo: style)
    }

    private static func headingSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: return 32
        case .title: return 24
        case .title2: return 20
        case .title3: return 20
        case .headline: return 16
        default: return 14
        }
    }

    private static func labelSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .title3: return 20
        case .headline: return 16
        case .body: return 16
        case .callout, .subheadline: return 14
        case .footnote: return 13
        default: return 12
        }
    }

    private static func bodySize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .title2: return 20
        case .title3: return 18
        case .body: return 16
        case .callout, .subheadline: return 14
        default: return 13
        }
    }

    private static func captionSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .headline, .body: return 16
        case .callout, .subheadline: return 14
        case .footnote: return 13
        default: return 12
        }
    }

    /// iOS registers `UIAppFonts` automatically. The macOS target uses the
    /// same bundled files and registers them for this process at launch.
    static func registerBundledFonts() {
#if os(macOS)
        [
            "Geist-Regular",
            "Geist-Medium",
            "Geist-SemiBold",
            "GeistMono-Regular",
            "GeistMono-Medium",
        ].forEach { name in
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { return }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
#endif
    }
}

// MARK: - Adaptive color implementation

private func adaptive(_ light: String, _ dark: String) -> Color {
#if canImport(UIKit)
    Color(uiColor: UIColor { traits in
        platformColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
    })
#elseif canImport(AppKit)
    Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return platformColor(hex: isDark ? dark : light)
    })
#else
    Color.primary
#endif
}

#if canImport(UIKit)
private func platformColor(hex: String) -> UIColor {
    let rgba = rgbaComponents(hex)
    return UIColor(red: rgba.0, green: rgba.1, blue: rgba.2, alpha: rgba.3)
}
#elseif canImport(AppKit)
private func platformColor(hex: String) -> NSColor {
    let rgba = rgbaComponents(hex)
    return NSColor(srgbRed: rgba.0, green: rgba.1, blue: rgba.2, alpha: rgba.3)
}
#endif

private func rgbaComponents(_ hex: String) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
    let value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    var raw: UInt64 = 0
    Scanner(string: value).scanHexInt64(&raw)
    if value.count == 8 {
        return (
            CGFloat((raw >> 24) & 0xff) / 255,
            CGFloat((raw >> 16) & 0xff) / 255,
            CGFloat((raw >> 8) & 0xff) / 255,
            CGFloat(raw & 0xff) / 255
        )
    }
    return (
        CGFloat((raw >> 16) & 0xff) / 255,
        CGFloat((raw >> 8) & 0xff) / 255,
        CGFloat(raw & 0xff) / 255,
        1
    )
}

// MARK: - Components

struct GeistButtonStyle: ButtonStyle {
    enum Variant { case primary, secondary, tertiary, destructive }
    enum Size { case small, medium, large }

    let variant: Variant
    var size: Size = .large
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(size == .large ? Geist.label(.body) : Geist.label())
            .foregroundStyle(foregroundColor)
            .frame(maxWidth: .infinity)
            .frame(minHeight: height)
            .padding(.horizontal, horizontalPadding)
            .background(backgroundColor(configuration.isPressed))
            .overlay(
                RoundedRectangle(cornerRadius: Geist.Radius.small, style: .continuous)
                    .stroke(borderColor(configuration.isPressed), lineWidth: borderWidth)
            )
            .clipShape(RoundedRectangle(cornerRadius: Geist.Radius.small, style: .continuous))
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: Geist.Radius.small + 2, style: .continuous)
                        .stroke(Geist.Palette.background100, lineWidth: 2)
                        .padding(-2)
                    RoundedRectangle(cornerRadius: Geist.Radius.small + 4, style: .continuous)
                        .stroke(Geist.focus, lineWidth: 2)
                        .padding(-4)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Geist.Radius.small, style: .continuous))
            .opacity(isEnabled ? 1 : 0.72)
    }

    private var height: CGFloat {
        switch size {
        case .small: return Geist.ControlHeight.small
        case .medium: return Geist.ControlHeight.medium
        case .large: return Geist.ControlHeight.large
        }
    }

    private var horizontalPadding: CGFloat { size == .small ? 6 : (size == .large ? 14 : 10) }

    private var foregroundColor: Color {
        guard isEnabled else { return Geist.Palette.gray700 }
        switch variant {
        case .primary: return Geist.Palette.background100
        case .secondary, .tertiary: return Geist.Palette.gray1000
        case .destructive: return .white
        }
    }

    private func backgroundColor(_ pressed: Bool) -> Color {
        guard isEnabled else { return Geist.Palette.gray100 }
        switch variant {
        case .primary: return pressed ? Geist.Palette.gray900 : Geist.Palette.gray1000
        case .secondary: return pressed ? Geist.Palette.grayAlpha300 : Geist.Palette.background100
        case .tertiary: return pressed ? Geist.Palette.grayAlpha200 : .clear
        case .destructive: return pressed ? Geist.Palette.red700 : Geist.Palette.red800
        }
    }

    private func borderColor(_ pressed: Bool) -> Color {
        guard variant == .secondary else { return .clear }
        return pressed ? Geist.Palette.grayAlpha600 : Geist.Palette.grayAlpha400
    }

    private var borderWidth: CGFloat { variant == .secondary ? 1 : 0 }
}

struct GeistDivider: View {
    var body: some View {
        Rectangle().fill(Geist.Palette.grayAlpha400).frame(height: 1)
    }
}

struct GeistStatusBadge: View {
    let label: LocalizedStringKey
    let isActive: Bool

    var body: some View {
        HStack(spacing: Geist.Spacing.two) {
            Circle()
                .fill(isActive ? Geist.Palette.blue900 : Geist.Palette.gray700)
                .frame(width: 6, height: 6)
            Text(label)
                .font(Geist.caption())
                .foregroundStyle(isActive ? Geist.Palette.blue900 : Geist.Palette.gray900)
        }
        .padding(.horizontal, Geist.Spacing.three)
        .frame(height: Geist.ControlHeight.small)
        .background(isActive ? Geist.Palette.blue100 : Geist.Palette.gray100)
        .clipShape(Capsule())
    }
}

struct GeistSectionLabel: View {
    let number: String
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(Geist.heading(.footnote))
            .foregroundStyle(Geist.Palette.gray1000)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(title)
    }
}

/// Retained as an API-compatible background while deliberately rendering no
/// decoration. Geist uses whitespace, tonal surfaces, and borders for depth.
struct GeistGridBackground: View {
    var spacing: CGFloat = 52
    var lineOpacity: Double = 0

    var body: some View { Color.clear }
}

struct IdleWaveformView: View {
    private let barCount = 9

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.15)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: Geist.Spacing.one) {
                ForEach(0..<barCount, id: \.self) { index in
                    let phase = time * 2 + Double(index) * 0.55
                    let height = (sin(phase) + 1) / 2 * 22 + 5
                    Capsule()
                        .fill(Geist.Palette.blue700)
                        .frame(width: 3, height: height)
                }
            }
            .frame(height: 28)
        }
        .accessibilityHidden(true)
    }
}

struct TranscribingDotsView: View {
    var body: some View {
        HStack(spacing: Geist.Spacing.three) {
            ProgressView().tint(Geist.Palette.blue700)
            Text("Transcribing…")
                .font(Geist.heading(.title2))
                .foregroundStyle(Geist.text)
        }
    }
}

struct GeistCardModifier: ViewModifier {
    var padding: CGFloat = Geist.Spacing.six
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Geist.Palette.background100)
            .overlay(
                RoundedRectangle(cornerRadius: Geist.Radius.medium, style: .continuous)
                    .stroke(Geist.Palette.grayAlpha400, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Geist.Radius.medium, style: .continuous))
            .shadow(
                color: .black.opacity(colorScheme == .dark ? 0.16 : 0.04),
                radius: 2,
                x: 0,
                y: colorScheme == .dark ? 1 : 2
            )
    }
}

extension View {
    func geistCard(padding: CGFloat = Geist.Spacing.six) -> some View {
        modifier(GeistCardModifier(padding: padding))
    }
}
