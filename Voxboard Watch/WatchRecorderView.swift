import SwiftUI

// MARK: - Watch Design Tokens

private enum WatchGeist {
    // Exact Geist dark-theme values from docs/geist/design.dark.md.
    static let bg = Color.black
    static let surface = Color(red: 0.102, green: 0.102, blue: 0.102) // gray-100
    static let surface2 = Color(red: 0.122, green: 0.122, blue: 0.122) // gray-200
    static let border = Color.white.opacity(0.141) // gray-alpha-400
    static let borderHi = Color.white.opacity(0.239) // gray-alpha-500
    static let text = Color(red: 0.929, green: 0.929, blue: 0.929) // gray-1000
    static let muted = Color(red: 0.627, green: 0.627, blue: 0.627) // gray-900
    static let faint = Color(red: 0.561, green: 0.561, blue: 0.561) // gray-700
    static let error = Color(red: 1.0, green: 0.337, blue: 0.373) // red-900

    static func display(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .default)
    }

    static func label(_ style: Font.TextStyle = .caption) -> Font {
        .system(style, design: .default, weight: .medium)
    }

    static func body(_ style: Font.TextStyle = .footnote) -> Font {
        .system(style, design: .default, weight: .regular)
    }

    static func caption(_ style: Font.TextStyle = .caption2) -> Font {
        .system(style, design: .default, weight: .regular)
    }
}

private struct WatchGeistGridBackground: View {
    var spacing: CGFloat = 22
    var lineOpacity: Double = 0.16

    var body: some View { Color.clear }

}

private struct WatchGeistDivider: View {
    var body: some View {
        Rectangle()
            .fill(WatchGeist.border)
            .frame(height: 1)
    }
}

private struct WatchStatusBadge: View {
    let label: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 5) {
            Rectangle()
                .fill(isActive ? WatchGeist.text : WatchGeist.faint)
                .frame(width: 5, height: 5)
            Text(label)
                .font(WatchGeist.caption())
                .foregroundStyle(isActive ? WatchGeist.text : WatchGeist.faint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .overlay(Rectangle().stroke(isActive ? WatchGeist.borderHi : WatchGeist.border, lineWidth: 1))
    }
}

private struct WatchSectionLabel: View {
    let number: String
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Text(number)
                .font(WatchGeist.caption())
                .foregroundStyle(WatchGeist.faint)
            Rectangle()
                .fill(WatchGeist.border)
                .frame(width: 13, height: 1)
            Text(title)
                .font(WatchGeist.caption())
                .foregroundStyle(WatchGeist.faint)
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
            Text(label)
                .font(WatchGeist.caption())
                .foregroundStyle(WatchGeist.faint)
                .lineLimit(1)
            Text(value)
                .font(WatchGeist.label(.caption2))
                .foregroundStyle(WatchGeist.text)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(WatchGeist.surface.opacity(0.72))
        .overlay(Rectangle().stroke(WatchGeist.border, lineWidth: 1))
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
                        .fill(WatchGeist.text.opacity(isActive ? 0.82 : 0.38))
                        .frame(width: 3, height: height)
                }
            }
            .frame(height: 26)
        }
        .accessibilityHidden(true)
    }
}

private struct WatchGeistButtonStyle: ButtonStyle {
    enum Variant {
        case primary
        case secondary
        case destructive
    }

    let variant: Variant
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(WatchGeist.label(.footnote))
            .foregroundStyle(foregroundColor(isPressed: configuration.isPressed))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(backgroundColor(isPressed: configuration.isPressed))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(borderColor(isPressed: configuration.isPressed), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1.0) : 0.45)
    }

    private func foregroundColor(isPressed: Bool) -> Color {
        switch variant {
        case .primary:
            return WatchGeist.bg
        case .secondary:
            return isPressed ? WatchGeist.muted : WatchGeist.text
        case .destructive:
            return WatchGeist.text
        }
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        switch variant {
        case .primary:
            return isPressed ? Color(white: 0.82) : WatchGeist.text
        case .secondary:
            return isPressed ? WatchGeist.surface2 : WatchGeist.surface.opacity(0.58)
        case .destructive:
            return isPressed ? WatchGeist.error.opacity(0.74) : WatchGeist.error
        }
    }

    private func borderColor(isPressed: Bool) -> Color {
        switch variant {
        case .primary, .destructive:
            return .clear
        case .secondary:
            return isPressed ? WatchGeist.borderHi : WatchGeist.border
        }
    }
}

struct WatchRecorderView: View {
    @EnvironmentObject private var bridge: WatchPhoneBridge
    @EnvironmentObject private var localRecorder: WatchLocalRecorder
    @State private var isSending = false

    var body: some View {
        ZStack {
            WatchGeist.bg.ignoresSafeArea()
            WatchGeistGridBackground()
                .ignoresSafeArea()
                .allowsHitTesting(false)

            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    topBar
                    WatchGeistDivider()

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
            // Reconcile terminal iPhone state before scheduling any transfer so
            // a delivered/discarded recording cannot be retransmitted on launch.
            localRecorder.applyRemoteStatuses(bridge.snapshot.recordingStatuses, using: bridge)
            localRecorder.syncPending(using: bridge)
        }
        .onChange(of: bridge.snapshot) { _, snapshot in
            localRecorder.applyRemoteStatuses(snapshot.recordingStatuses, using: bridge)
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
                        .stroke(WatchGeist.borderHi.opacity(0.45), lineWidth: 0.5)
                )
                .accessibilityLabel("Vox.md")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(WatchGeist.bg.opacity(0.9))
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
                    .fill(WatchGeist.surface.opacity(0.78))
                    .overlay(Rectangle().stroke(WatchGeist.border, lineWidth: 1))

                Image(systemName: symbolName)
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(symbolColor)
            }
            .frame(width: 42, height: 42)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(phaseWord)
                    .font(WatchGeist.display(compactDisplaySize))
                    .foregroundStyle(phaseWordColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.45)
                    .accessibilityAddTraits(localRecorder.isRecording ? .updatesFrequently : [])

                if localRecorder.isRecording,
                   let startedAt = localRecorder.startedAt {
                    Text(startedAt, style: .timer)
                        .font(WatchGeist.display(25))
                        .foregroundStyle(WatchGeist.text)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.62)

                    Text("Tap again to stop.")
                        .font(WatchGeist.caption())
                        .foregroundStyle(WatchGeist.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                } else {
                    Text(mainSubtitle)
                        .font(WatchGeist.caption())
                        .foregroundStyle(WatchGeist.muted)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(9)
        .background(WatchGeist.bg.opacity(0.58))
        .overlay(Rectangle().stroke(WatchGeist.border, lineWidth: 1))
        .contentShape(Rectangle())
        .opacity(isSending ? 0.7 : 1.0)
    }

    private var secondarySyncButton: some View {
        Button {
            Task { await syncQueueOrRefreshStatus() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isSending ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                Text(localRecorder.syncTitle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.58)
            }
        }
        .buttonStyle(WatchGeistButtonStyle(variant: .secondary))
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
                .font(WatchGeist.caption())
                .foregroundStyle(WatchGeist.muted)
                .lineLimit(3)
                .minimumScaleFactor(0.75)

            if localRecorder.isRecording {
                WatchWaveformView(isActive: true)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(WatchGeist.surface.opacity(0.52))
        .overlay(Rectangle().stroke(WatchGeist.border, lineWidth: 1))
    }

    private var metricsRow: some View {
        HStack(spacing: 8) {
            WatchMetricTile(label: "Queue", value: "\(localRecorder.queuedCount)")
            WatchMetricTile(label: "Preset", value: localRecorder.activePresetName)
            WatchMetricTile(label: "Sync", value: syncMetricValue)
        }
    }

    @ViewBuilder
    private var queueCard: some View {
        if shouldShowQueueSummary {
            VStack(alignment: .leading, spacing: 7) {
                WatchSectionLabel(number: "02", title: "Queue")
                Text(localRecorder.queueSummary)
                    .font(WatchGeist.caption())
                    .foregroundStyle(WatchGeist.text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                Text("Saved locally. Sync when your iPhone is nearby.")
                    .font(WatchGeist.caption())
                    .foregroundStyle(WatchGeist.muted)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(WatchGeist.surface.opacity(0.52))
            .overlay(Rectangle().stroke(WatchGeist.border, lineWidth: 1))
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
        case .waitingForPhone:
            return "QUEUED."
        case .transcribing:
            return "TRANSCRIBING."
        case .delivering:
            return "SAVING."
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
        case .transferring, .waitingForPhone, .delivering:
            return 25
        case .transcribing:
            return 20
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
        case .waitingForPhone:
            return "Safe on iPhone."
        case .transcribing:
            return "Processing on iPhone…"
        case .delivering:
            return "Saving to Capture…"
        case .transferred:
            return "Saved to Capture."
        case .error:
            if localRecorder.queuedRecordings.contains(where: { $0.remotePhase == .failed }) {
                return "Open iPhone to retry."
            }
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
        case .waitingForPhone:
            return "Queued"
        case .transcribing:
            return "Transcribe"
        case .delivering:
            return "Saving"
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
        case .recording, .transferring, .waitingForPhone, .transcribing, .delivering, .transferred, .error:
            return true
        }
    }

    private var syncMetricValue: String {
        switch localRecorder.phase {
        case .transferring:
            return "On"
        case .waitingForPhone:
            return "Queue"
        case .transcribing:
            return "Text"
        case .delivering:
            return "Save"
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
            return WatchGeist.error
        default:
            return WatchGeist.text
        }
    }

    private var symbolName: String {
        switch localRecorder.phase {
        case .recording:
            return "waveform"
        case .transferring:
            return "iphone.radiowaves.left.and.right"
        case .waitingForPhone:
            return "iphone.badge.checkmark"
        case .transcribing:
            return "waveform.badge.magnifyingglass"
        case .delivering:
            return "arrow.up.doc"
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
            return WatchGeist.error
        case .idle:
            return localRecorder.queuedCount > 0 ? WatchGeist.text : WatchGeist.muted
        default:
            return WatchGeist.text
        }
    }

    private var accessibilityStatusLabel: String {
        if localRecorder.isRecording, let startedAt = localRecorder.startedAt {
            let elapsed = Date().timeIntervalSince(startedAt)
            return "Vox.md recording for \(Int(elapsed)) seconds."
        }
        return "Vox.md Watch status: \(phaseBadgeLabel). \(localRecorder.subtitle)"
    }

    private func toggleRecording() async {
        isSending = true
        defer { isSending = false }
        await localRecorder.toggle(using: bridge)
    }

    private func syncQueueOrRefreshStatus() async {
        isSending = true
        defer { isSending = false }
        if localRecorder.hasUnuploadedRecordings {
            localRecorder.syncPending(using: bridge)
        } else {
            let snapshot = await bridge.requestStatus()
            localRecorder.applyRemoteStatuses(snapshot.recordingStatuses, using: bridge)
        }
    }
}

#Preview {
    WatchRecorderView()
        .environmentObject(WatchPhoneBridge.shared)
        .environmentObject(WatchLocalRecorder())
}
