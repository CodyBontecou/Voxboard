import SwiftUI

// MARK: - Watch Design Tokens

private enum WatchBrutal {
    static let bg = Color.black
    static let surface = Color(white: 0.067)
    static let surface2 = Color(white: 0.1)
    static let border = Color(white: 0.165)
    static let borderHi = Color(white: 0.36)
    static let text = Color.white
    static let muted = Color(white: 0.72)
    static let faint = Color(white: 0.58)
    static let error = Color(red: 1.0, green: 0.271, blue: 0.227)

    static func display(_ size: CGFloat) -> Font {
        .system(size: size, weight: .heavy, design: .monospaced)
    }

    static func label(_ style: Font.TextStyle = .caption) -> Font {
        .system(style, design: .monospaced, weight: .semibold)
    }

    static func body(_ style: Font.TextStyle = .footnote) -> Font {
        .system(style, design: .monospaced, weight: .regular)
    }

    static func caption(_ style: Font.TextStyle = .caption2) -> Font {
        .system(style, design: .monospaced, weight: .regular)
    }
}

private struct WatchBrutalGridBackground: View {
    var spacing: CGFloat = 22
    var lineOpacity: Double = 0.16

    var body: some View {
        Canvas { context, size in
            let shading = GraphicsContext.Shading.color(Color.white.opacity(lineOpacity))

            var x: CGFloat = 0
            while x <= size.width {
                let path = Path { path in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
                context.stroke(path, with: shading, lineWidth: 0.5)
                x += spacing
            }

            var y: CGFloat = 0
            while y <= size.height {
                let path = Path { path in
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(path, with: shading, lineWidth: 0.5)
                y += spacing
            }
        }
        .mask(
            LinearGradient(
                colors: [.black.opacity(0.92), .black.opacity(0.35), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

private struct WatchBrutalDivider: View {
    var body: some View {
        Rectangle()
            .fill(WatchBrutal.border)
            .frame(height: 1)
    }
}

private struct WatchStatusBadge: View {
    let label: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 5) {
            Rectangle()
                .fill(isActive ? WatchBrutal.text : WatchBrutal.faint)
                .frame(width: 5, height: 5)
            Text(label.uppercased())
                .font(WatchBrutal.caption())
                .foregroundStyle(isActive ? WatchBrutal.text : WatchBrutal.faint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .overlay(Rectangle().stroke(isActive ? WatchBrutal.borderHi : WatchBrutal.border, lineWidth: 1))
    }
}

private struct WatchSectionLabel: View {
    let number: String
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Text(number)
                .font(WatchBrutal.caption())
                .foregroundStyle(WatchBrutal.faint)
            Rectangle()
                .fill(WatchBrutal.border)
                .frame(width: 13, height: 1)
            Text(title.uppercased())
                .font(WatchBrutal.caption())
                .foregroundStyle(WatchBrutal.faint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WatchMetricTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(WatchBrutal.caption())
                .foregroundStyle(WatchBrutal.faint)
                .lineLimit(1)
            Text(value.uppercased())
                .font(WatchBrutal.label(.caption2))
                .foregroundStyle(WatchBrutal.text)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(WatchBrutal.surface.opacity(0.72))
        .overlay(Rectangle().stroke(WatchBrutal.border, lineWidth: 1))
    }
}

private struct WatchWaveformView: View {
    let isActive: Bool
    private let barCount = 9

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<barCount, id: \.self) { index in
                    let phase = isActive ? t * 4.5 + Double(index) * 0.62 : Double(index) * 0.45
                    let height = (sin(phase) + 1) / 2 * 18 + 4
                    Rectangle()
                        .fill(WatchBrutal.text.opacity(isActive ? 0.82 : 0.38))
                        .frame(width: 3, height: height)
                }
            }
            .frame(height: 26)
        }
        .accessibilityHidden(true)
    }
}

private struct WatchBrutalButtonStyle: ButtonStyle {
    enum Variant {
        case primary
        case secondary
        case destructive
    }

    let variant: Variant
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(WatchBrutal.label(.footnote))
            .foregroundStyle(foregroundColor(isPressed: configuration.isPressed))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(backgroundColor(isPressed: configuration.isPressed))
            .overlay(Rectangle().stroke(borderColor(isPressed: configuration.isPressed), lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1.0) : 0.45)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }

    private func foregroundColor(isPressed: Bool) -> Color {
        switch variant {
        case .primary:
            return WatchBrutal.bg
        case .secondary:
            return isPressed ? WatchBrutal.muted : WatchBrutal.text
        case .destructive:
            return WatchBrutal.text
        }
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        switch variant {
        case .primary:
            return isPressed ? Color(white: 0.82) : WatchBrutal.text
        case .secondary:
            return isPressed ? WatchBrutal.surface2 : WatchBrutal.surface.opacity(0.58)
        case .destructive:
            return isPressed ? WatchBrutal.error.opacity(0.74) : WatchBrutal.error
        }
    }

    private func borderColor(isPressed: Bool) -> Color {
        switch variant {
        case .primary, .destructive:
            return .clear
        case .secondary:
            return isPressed ? WatchBrutal.borderHi : WatchBrutal.border
        }
    }
}

struct WatchRecorderView: View {
    @EnvironmentObject private var bridge: WatchPhoneBridge
    @EnvironmentObject private var localRecorder: WatchLocalRecorder
    @State private var isSending = false

    var body: some View {
        ZStack {
            WatchBrutal.bg.ignoresSafeArea()
            WatchBrutalGridBackground()
                .ignoresSafeArea()
                .allowsHitTesting(false)

            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    topBar
                    WatchBrutalDivider()

                    VStack(spacing: 8) {
                        mainStatusPanel

                        if shouldShowSecondaryAction {
                            secondarySyncButton
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 6)

                    detailsContent
                }
            }
            .scrollIndicators(.hidden)
        }
        .preferredColorScheme(.dark)
        .task {
            bridge.activate()
            try? await Task.sleep(nanoseconds: 750_000_000)
            #if DEBUG
            if localRecorder.runDemoScriptIfNeeded(using: bridge) { return }
            #endif
            localRecorder.syncPending(using: bridge)
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            WatchStatusBadge(label: phaseBadgeLabel, isActive: statusBadgeIsActive)
            Spacer(minLength: 4)
            Image("WatchTopBarIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(WatchBrutal.borderHi.opacity(0.45), lineWidth: 0.5)
                )
                .accessibilityLabel("Voxboard")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(WatchBrutal.bg.opacity(0.9))
    }

    private var mainStatusPanel: some View {
        Button {
            Task { await toggleRecording() }
        } label: {
            mainStatusPanelContent
        }
        .buttonStyle(.plain)
        .disabled(isSending)
        .accessibilityLabel(accessibilityStatusLabel)
        .accessibilityHint(localRecorder.isRecording ? "Stops and saves the Watch recording." : "Starts a local Watch recording.")
    }

    private var mainStatusPanelContent: some View {
        HStack(spacing: 10) {
            ZStack {
                Rectangle()
                    .fill(WatchBrutal.surface.opacity(0.78))
                    .overlay(Rectangle().stroke(WatchBrutal.border, lineWidth: 1))

                Image(systemName: symbolName)
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(symbolColor)
            }
            .frame(width: 42, height: 42)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(phaseWord)
                    .font(WatchBrutal.display(compactDisplaySize))
                    .foregroundStyle(phaseWordColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.45)
                    .accessibilityAddTraits(localRecorder.isRecording ? .updatesFrequently : [])

                if localRecorder.isRecording,
                   let startedAt = localRecorder.startedAt {
                    Text(startedAt, style: .timer)
                        .font(WatchBrutal.display(25))
                        .foregroundStyle(WatchBrutal.text)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.62)

                    Text("Tap again to stop.")
                        .font(WatchBrutal.caption())
                        .foregroundStyle(WatchBrutal.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                } else {
                    Text(mainSubtitle)
                        .font(WatchBrutal.caption())
                        .foregroundStyle(WatchBrutal.muted)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(9)
        .background(WatchBrutal.bg.opacity(0.58))
        .overlay(Rectangle().stroke(WatchBrutal.border, lineWidth: 1))
        .contentShape(Rectangle())
        .opacity(isSending ? 0.7 : 1.0)
    }

    private var secondarySyncButton: some View {
        Button {
            Task { await syncQueueOrRefreshStatus() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isSending ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                Text(localRecorder.syncTitle.uppercased())
                    .lineLimit(1)
                    .minimumScaleFactor(0.58)
            }
        }
        .buttonStyle(WatchBrutalButtonStyle(variant: .secondary))
        .disabled(isSending || localRecorder.isRecording)
        .accessibilityHint(localRecorder.queuedCount > 0 ? "Sends saved Watch recordings to your iPhone." : "Refreshes the connection with your iPhone.")
    }

    private var detailsContent: some View {
        VStack(spacing: 8) {
            statusDetailCard
            metricsRow
            queueCard
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    private var statusDetailCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            WatchSectionLabel(number: "01", title: "Details")
            Text(localRecorder.subtitle)
                .font(WatchBrutal.caption())
                .foregroundStyle(WatchBrutal.muted)
                .lineLimit(3)
                .minimumScaleFactor(0.75)

            if localRecorder.isRecording {
                WatchWaveformView(isActive: true)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(WatchBrutal.surface.opacity(0.52))
        .overlay(Rectangle().stroke(WatchBrutal.border, lineWidth: 1))
    }

    private var metricsRow: some View {
        HStack(spacing: 8) {
            WatchMetricTile(label: "Queue", value: "\(localRecorder.queuedCount)")
            WatchMetricTile(label: "Mode", value: "Local")
            WatchMetricTile(label: "Sync", value: syncMetricValue)
        }
    }

    @ViewBuilder
    private var queueCard: some View {
        if shouldShowQueueSummary {
            VStack(alignment: .leading, spacing: 7) {
                WatchSectionLabel(number: "02", title: "Queue")
                Text(localRecorder.queueSummary.uppercased())
                    .font(WatchBrutal.caption())
                    .foregroundStyle(WatchBrutal.text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                Text("Saved locally. Sync when your iPhone is nearby.")
                    .font(WatchBrutal.caption())
                    .foregroundStyle(WatchBrutal.muted)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(WatchBrutal.surface.opacity(0.52))
            .overlay(Rectangle().stroke(WatchBrutal.border, lineWidth: 1))
        }
    }

    private var shouldShowQueueSummary: Bool {
        guard localRecorder.queuedCount > 0, !localRecorder.isRecording else { return false }
        #if DEBUG
        return !localRecorder.isRunningDemoScript
        #else
        return true
        #endif
    }

    private var phaseWord: String {
        switch localRecorder.phase {
        case .recording:
            return "RECORDING."
        case .transferring:
            return "SYNCING."
        case .transferred:
            return "SAVED."
        case .error:
            return "ERROR."
        case .idle:
            return localRecorder.queuedCount > 0 ? "SAVED." : "READY."
        }
    }

    private var compactDisplaySize: CGFloat {
        switch localRecorder.phase {
        case .recording:
            return 23
        case .transferring:
            return 25
        case .transferred, .error, .idle:
            return 29
        }
    }

    private var mainSubtitle: String {
        switch localRecorder.phase {
        case .recording:
            return "Tap again to stop."
        case .transferring:
            return "Sending to iPhone…"
        case .transferred:
            return "Sent to iPhone queue."
        case .error:
            return localRecorder.queuedCount > 0 ? "Saved locally. Retry sync." : "Tap sync to refresh."
        case .idle:
            return localRecorder.queuedCount > 0 ? "\(localRecorder.queuedCount) saved on Watch." : "Tap to start."
        }
    }

    private var shouldShowSecondaryAction: Bool {
        guard !localRecorder.isRecording else { return false }
        if localRecorder.queuedCount > 0 { return true }
        if case .error = localRecorder.phase { return true }
        return false
    }

    private var phaseBadgeLabel: String {
        switch localRecorder.phase {
        case .recording:
            return "Recording"
        case .transferring:
            return "Sync"
        case .transferred:
            return "Sent"
        case .error:
            return "Alert"
        case .idle:
            return localRecorder.queuedCount > 0 ? "Queued" : "Ready"
        }
    }

    private var statusBadgeIsActive: Bool {
        switch localRecorder.phase {
        case .idle:
            return localRecorder.queuedCount > 0
        case .recording, .transferring, .transferred, .error:
            return true
        }
    }

    private var syncMetricValue: String {
        switch localRecorder.phase {
        case .transferring:
            return "On"
        case .transferred:
            return "Sent"
        case .error:
            return "Retry"
        case .idle, .recording:
            return localRecorder.queuedCount > 0 ? "Wait" : "Ready"
        }
    }

    private var phaseWordColor: Color {
        switch localRecorder.phase {
        case .error:
            return WatchBrutal.error
        default:
            return WatchBrutal.text
        }
    }

    private var symbolName: String {
        switch localRecorder.phase {
        case .recording:
            return "waveform"
        case .transferring:
            return "iphone.radiowaves.left.and.right"
        case .transferred:
            return "checkmark"
        case .error:
            return "exclamationmark.triangle.fill"
        case .idle:
            return localRecorder.queuedCount > 0 ? "tray.full" : "mic.fill"
        }
    }

    private var symbolColor: Color {
        switch localRecorder.phase {
        case .error:
            return WatchBrutal.error
        case .idle:
            return localRecorder.queuedCount > 0 ? WatchBrutal.text : WatchBrutal.muted
        default:
            return WatchBrutal.text
        }
    }

    private var accessibilityStatusLabel: String {
        if localRecorder.isRecording, let startedAt = localRecorder.startedAt {
            let elapsed = Date().timeIntervalSince(startedAt)
            return "Voxboard recording for \(Int(elapsed)) seconds."
        }
        return "Voxboard Watch status: \(phaseBadgeLabel). \(localRecorder.subtitle)"
    }

    private func toggleRecording() async {
        isSending = true
        defer { isSending = false }
        await localRecorder.toggle(using: bridge)
    }

    private func syncQueueOrRefreshStatus() async {
        isSending = true
        defer { isSending = false }
        if localRecorder.queuedCount > 0 {
            localRecorder.syncPending(using: bridge)
        } else {
            await bridge.requestStatus()
        }
    }
}

#Preview {
    WatchRecorderView()
        .environmentObject(WatchPhoneBridge.shared)
        .environmentObject(WatchLocalRecorder())
}
