import SwiftUI

// MARK: - Watch design system

/// A compact watchOS translation of the iOS Geist theme. The Watch keeps the
/// system typeface for legibility while sharing the iOS palette, spacing,
/// rounded controls, and semantic status colors.
private enum WatchGeist {
    enum Spacing {
        static let one: CGFloat = 4
        static let two: CGFloat = 8
        static let three: CGFloat = 12
        static let four: CGFloat = 16
    }

    enum Radius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let full: CGFloat = 9_999
    }

    // Dark values from the iOS Geist palette.
    static let background = Color(red: 0.102, green: 0.102, blue: 0.110)
    static let surface = Color(red: 0.122, green: 0.122, blue: 0.122)
    static let surfacePressed = Color(red: 0.161, green: 0.161, blue: 0.161)
    static let border = Color.white.opacity(0.141)
    static let borderHigh = Color.white.opacity(0.239)
    static let text = Color(red: 0.929, green: 0.929, blue: 0.929)
    static let muted = Color(red: 0.627, green: 0.627, blue: 0.627)
    static let faint = Color(red: 0.561, green: 0.561, blue: 0.561)
    static let blue = Color(red: 0.278, green: 0.659, blue: 1.0)
    static let blueBackground = Color(red: 0.024, green: 0.098, blue: 0.227)
    static let red = Color(red: 1.0, green: 0.337, blue: 0.373)
    static let redBackground = Color(red: 0.200, green: 0.039, blue: 0.067)

    static func heading(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .default)
    }

    static func label(_ style: Font.TextStyle = .footnote) -> Font {
        .system(style, design: .default, weight: .medium)
    }

    static func body(_ style: Font.TextStyle = .footnote) -> Font {
        .system(style, design: .default, weight: .regular)
    }

    static func caption(_ style: Font.TextStyle = .caption2) -> Font {
        .system(style, design: .default, weight: .regular)
    }
}

private enum WatchStatusTone: Equatable {
    case neutral
    case active
    case destructive

    var foreground: Color {
        switch self {
        case .neutral: WatchGeist.muted
        case .active: WatchGeist.blue
        case .destructive: WatchGeist.red
        }
    }

    var background: Color {
        switch self {
        case .neutral: WatchGeist.surface
        case .active: WatchGeist.blueBackground
        case .destructive: WatchGeist.redBackground
        }
    }
}

private struct WatchStatusBadge: View {
    let label: String
    let tone: WatchStatusTone

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tone.foreground)
                .frame(width: 5, height: 5)
            Text(label)
                .font(WatchGeist.caption())
                .foregroundStyle(tone.foreground)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, WatchGeist.Spacing.two)
        .frame(height: 26)
        .background(tone.background)
        .clipShape(Capsule())
    }
}

private struct WatchWaveformView: View {
    let color: Color
    private let barCount = 9

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<barCount, id: \.self) { index in
                    let phase = time * 4.5 + Double(index) * 0.62
                    let height = (sin(phase) + 1) / 2 * 16 + 5
                    Capsule()
                        .fill(color)
                        .frame(width: 3, height: height)
                }
            }
            .frame(height: 24)
        }
        .accessibilityHidden(true)
    }
}

private struct WatchGeistButtonStyle: ButtonStyle {
    enum Variant: Equatable {
        case primary
        case secondary
        case destructive
    }

    let variant: Variant
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(WatchGeist.label())
            .foregroundStyle(foregroundColor)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .padding(.horizontal, WatchGeist.Spacing.two)
            .background(backgroundColor(isPressed: configuration.isPressed))
            .overlay {
                if variant == .secondary {
                    RoundedRectangle(cornerRadius: WatchGeist.Radius.small, style: .continuous)
                        .stroke(configuration.isPressed ? WatchGeist.borderHigh : WatchGeist.border, lineWidth: 1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: WatchGeist.Radius.small, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: WatchGeist.Radius.small, style: .continuous))
            .opacity(isEnabled ? 1 : 0.55)
    }

    private var foregroundColor: Color {
        guard isEnabled else { return WatchGeist.faint }
        switch variant {
        case .primary:
            return WatchGeist.background
        case .secondary, .destructive:
            return WatchGeist.text
        }
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        guard isEnabled else { return WatchGeist.surface }
        switch variant {
        case .primary:
            return isPressed ? WatchGeist.muted : WatchGeist.text
        case .secondary:
            return isPressed ? WatchGeist.surfacePressed : WatchGeist.surface
        case .destructive:
            return isPressed ? WatchGeist.red.opacity(0.78) : WatchGeist.red
        }
    }
}

struct WatchRecorderView: View {
    @EnvironmentObject private var bridge: WatchPhoneBridge
    @EnvironmentObject private var localRecorder: WatchLocalRecorder
    @State private var isSending = false
    @State private var showsPresetPicker = false

    var body: some View {
        ZStack {
            WatchGeist.background.ignoresSafeArea()

            ScrollView(.vertical) {
                VStack(spacing: WatchGeist.Spacing.two) {
                    header
                    statusCard
                    actionButtons
                    captureContextCard
                }
                .padding(.horizontal, WatchGeist.Spacing.two)
                .padding(.top, 2)
                .padding(.bottom, WatchGeist.Spacing.three)
            }
            .scrollIndicators(.hidden)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showsPresetPicker) {
            WatchCapturePresetPickerView()
                .environmentObject(bridge)
                .environmentObject(localRecorder)
        }
        .task {
            #if DEBUG
            if localRecorder.configureLocalizationScreenshotIfNeeded() { return }
            #endif
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

    private var header: some View {
        HStack(spacing: WatchGeist.Spacing.two) {
            Image("WatchTopBarIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)

            Text("Vox.md")
                .font(WatchGeist.label(.caption))
                .foregroundStyle(WatchGeist.text)

            Spacer(minLength: WatchGeist.Spacing.one)
            WatchStatusBadge(label: phaseBadgeLabel, tone: statusTone)
        }
        .padding(.horizontal, 2)
        .frame(minHeight: 30)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Vox.md, \(phaseBadgeLabel)")
    }

    private var statusCard: some View {
        Group {
            if localRecorder.isRecording {
                recordingStatusContent
            } else {
                compactStatusContent
            }
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(WatchGeist.surface)
        .overlay(
            RoundedRectangle(cornerRadius: WatchGeist.Radius.medium, style: .continuous)
                .stroke(WatchGeist.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: WatchGeist.Radius.medium, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityStatusLabel)
    }

    private var compactStatusContent: some View {
        HStack(spacing: WatchGeist.Spacing.two) {
            statusIcon(size: 38, symbolSize: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(statusHeadline)
                    .font(WatchGeist.heading(statusHeadlineSize))
                    .foregroundStyle(statusTone == .destructive ? WatchGeist.red : WatchGeist.text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.68)

                Text(statusSubtitle)
                    .font(WatchGeist.caption())
                    .foregroundStyle(statusTone == .destructive ? WatchGeist.red : WatchGeist.muted)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var recordingStatusContent: some View {
        VStack(spacing: WatchGeist.Spacing.two) {
            HStack(spacing: WatchGeist.Spacing.three) {
                statusIcon(size: 44, symbolSize: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(localRecorder.isPaused ? String(localized: "Paused") : String(localized: "Recording"))
                        .font(WatchGeist.label(.caption))
                        .foregroundStyle(WatchGeist.text)
                    Text(formattedDuration(localRecorder.duration))
                        .font(.system(size: 27, weight: .semibold, design: .monospaced))
                        .foregroundStyle(WatchGeist.text)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: WatchGeist.Spacing.two) {
                if localRecorder.isPaused {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(WatchGeist.blue)
                        .frame(width: 64, height: 24)
                        .accessibilityHidden(true)
                } else {
                    WatchWaveformView(color: WatchGeist.red)
                        .frame(width: 64)
                }
                Text(localRecorder.isPaused
                     ? String(localized: "Resume • Stop • Cancel")
                     : String(localized: "Pause • Stop • Cancel"))
                    .font(WatchGeist.caption())
                    .foregroundStyle(WatchGeist.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func statusIcon(size: CGFloat, symbolSize: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(statusTone.background)
                .frame(width: size, height: size)

            Image(systemName: statusSymbolName)
                .font(.system(size: symbolSize, weight: .semibold))
                .foregroundStyle(statusTone.foreground)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var actionButtons: some View {
        if localRecorder.isRecording {
            VStack(spacing: WatchGeist.Spacing.two) {
                HStack(spacing: WatchGeist.Spacing.two) {
                    recordingButton
                    pauseResumeButton
                }
                cancelRecordingButton
            }
        } else if shouldShowSecondaryAction {
            HStack(spacing: WatchGeist.Spacing.two) {
                recordingButton
                secondarySyncButton
            }
        } else {
            recordingButton
        }
    }

    private var recordingButton: some View {
        Button {
            Task { await toggleRecording() }
        } label: {
            HStack(spacing: 6) {
                if isSending {
                    ProgressView()
                        .controlSize(.small)
                        .tint(localRecorder.isRecording ? WatchGeist.text : WatchGeist.background)
                } else {
                    Image(systemName: localRecorder.actionSymbol)
                }
                Text(localRecorder.actionTitle)
            }
        }
        .buttonStyle(
            WatchGeistButtonStyle(
                variant: localRecorder.isRecording ? .destructive : .primary
            )
        )
        .disabled(isSending || (!localRecorder.isRecording && !canStartRecording))
        .accessibilityLabel(localRecorder.isRecording
                            ? String(localized: "Stop Watch recording")
                            : String(localized: "Start Watch recording"))
        .accessibilityHint(localRecorder.isRecording
                           ? String(localized: "Stops and safely saves this recording.")
                           : String(localized: "Starts a recording stored locally on this Watch."))
    }

    private var pauseResumeButton: some View {
        Button {
            localRecorder.togglePause()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: localRecorder.isPaused ? "play.fill" : "pause.fill")
                Text(localRecorder.isPaused ? String(localized: "Resume") : String(localized: "Pause"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .buttonStyle(WatchGeistButtonStyle(variant: .secondary))
        .disabled(isSending)
        .accessibilityLabel(localRecorder.isPaused
                            ? String(localized: "Resume Watch recording")
                            : String(localized: "Pause Watch recording"))
        .accessibilityHint(localRecorder.isPaused
                           ? String(localized: "Continues adding audio to this recording.")
                           : String(localized: "Temporarily stops adding audio without ending the recording."))
    }

    private var cancelRecordingButton: some View {
        Button {
            Task { await cancelRecording() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "xmark")
                Text("Cancel")
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .buttonStyle(WatchGeistButtonStyle(variant: .secondary))
        .disabled(isSending)
        .accessibilityLabel("Cancel and delete Watch recording")
        .accessibilityHint("Stops and permanently deletes this recording without syncing it to your iPhone.")
    }

    private var secondarySyncButton: some View {
        Button {
            Task { await syncQueueOrRefreshStatus() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isSending ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                Text(localRecorder.hasUnuploadedRecordings
                     ? String(localized: "Sync")
                     : String(localized: "Refresh"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .buttonStyle(WatchGeistButtonStyle(variant: .secondary))
        .disabled(isSending || localRecorder.isRecording)
        .accessibilityHint(localRecorder.queuedCount > 0
                           ? String(localized: "Sends saved Watch recordings to your iPhone.")
                           : String(localized: "Refreshes the connection with your iPhone."))
    }

    private var captureContextCard: some View {
        Button {
            showsPresetPicker = true
        } label: {
            HStack(spacing: WatchGeist.Spacing.two) {
                Image(systemName: selectedPresetSymbolName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(WatchGeist.blue)
                    .frame(width: 26, height: 26)
                    .background(WatchGeist.blueBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Capture Preset")
                        .font(WatchGeist.caption())
                        .foregroundStyle(WatchGeist.muted)
                    Text(displayedPresetName)
                        .font(WatchGeist.label(.caption2))
                        .foregroundStyle(WatchGeist.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }

                Spacer(minLength: WatchGeist.Spacing.one)

                VStack(alignment: .trailing, spacing: 1) {
                    Text("Queue")
                        .font(WatchGeist.caption())
                        .foregroundStyle(WatchGeist.muted)
                    Text("\(localRecorder.queuedCount)")
                        .font(WatchGeist.label(.caption2))
                        .foregroundStyle(localRecorder.queuedCount > 0 ? WatchGeist.blue : WatchGeist.text)
                        .monospacedDigit()
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(WatchGeist.faint)
            }
            .padding(WatchGeist.Spacing.two)
            .background(WatchGeist.background)
            .overlay(
                RoundedRectangle(cornerRadius: WatchGeist.Radius.small, style: .continuous)
                    .stroke(WatchGeist.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: WatchGeist.Radius.small, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: WatchGeist.Radius.small, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(localRecorder.isRecording)
        .opacity(localRecorder.isRecording ? 0.55 : 1)
        .accessibilityLabel("Capture Preset \(displayedPresetName). Change preset. \(localRecorder.queuedCount) recordings in the Watch queue.")
        .accessibilityHint(localRecorder.isRecording
                           ? String(localized: "Finish recording before changing presets.")
                           : String(localized: "Shows Capture Presets from your iPhone."))
    }

    private var displayedPresetName: String {
        localRecorder.recordingPresetName
            ?? bridge.snapshot.selectedPresetName
            ?? String(localized: "iPhone Default")
    }

    private var selectedPresetSymbolName: String {
        bridge.snapshot.availablePresets.first(where: {
            $0.id == bridge.snapshot.selectedPresetID
        })?.symbolName ?? "waveform"
    }

    private var canStartRecording: Bool {
        guard bridge.snapshot.hasPresetSelectionAvailabilityPayload else { return true }
        return bridge.snapshot.presetSelectionIsAvailable
            && bridge.snapshot.selectedPresetSnapshot != nil
    }

    private var statusHeadline: String {
        if !localRecorder.isRecording, !canStartRecording {
            return String(localized: "Preset needed")
        }
        switch localRecorder.phase {
        case .recording:
            return String(localized: "Recording")
        case .paused:
            return String(localized: "Paused")
        case .transferring:
            return String(localized: "Syncing to iPhone")
        case .waitingForPhone:
            return String(localized: "On iPhone")
        case .transcribing:
            return String(localized: "Transcribing")
        case .delivering:
            return String(localized: "Saving on iPhone")
        case .transferred:
            return String(localized: "Saved on iPhone")
        case .error:
            return String(localized: "Needs attention")
        case .idle:
            return localRecorder.queuedCount > 0
                ? String(localized: "Ready")
                : String(localized: "Voice Capture")
        }
    }

    private var statusHeadlineSize: CGFloat {
        switch localRecorder.phase {
        case .transferring, .delivering, .transferred:
            return 16
        case .recording, .paused, .waitingForPhone, .transcribing, .error:
            return 18
        case .idle:
            return 17
        }
    }

    private var statusSubtitle: String {
        if !localRecorder.isRecording, !canStartRecording {
            return String(localized: "Enable a Capture Preset in Vox.md on iPhone.")
        }
        switch localRecorder.phase {
        case .recording:
            return String(localized: "Pause for a break, Stop to save, or Cancel to delete.")
        case .paused:
            if let message = localRecorder.message, !message.isEmpty {
                return message
            }
            return String(localized: "Resume to continue, Stop to save, or Cancel to delete.")
        case .transferring:
            return String(localized: "Your recording remains safe while it moves to iPhone.")
        case .waitingForPhone:
            return String(localized: "Safely queued and waiting to process.")
        case .transcribing:
            return String(localized: "Your iPhone is transcribing on device.")
        case .delivering:
            return String(localized: "Saving through your selected Capture Preset.")
        case .transferred:
            return String(localized: "Delivered successfully. You can record another.")
        case .error(let message):
            return message
        case .idle:
            if localRecorder.queuedCount == 1 {
                return String(localized: "1 recording safe on Watch.")
            }
            if localRecorder.queuedCount > 1 {
                return String(localized: "\(localRecorder.queuedCount) recordings safe on Watch.")
            }
            return String(localized: "Capture on Watch. Syncs to iPhone.")
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
            return String(localized: "Live")
        case .paused:
            return String(localized: "Paused")
        case .transferring:
            return String(localized: "Sync")
        case .waitingForPhone:
            return String(localized: "Queued")
        case .transcribing:
            return String(localized: "Text")
        case .delivering:
            return String(localized: "Save")
        case .transferred:
            return String(localized: "Sent")
        case .error:
            return String(localized: "Alert")
        case .idle:
            return localRecorder.queuedCount > 0
                ? String(localized: "Queue")
                : String(localized: "Ready")
        }
    }

    private var statusTone: WatchStatusTone {
        switch localRecorder.phase {
        case .recording, .error:
            return .destructive
        case .paused, .transferring, .waitingForPhone, .transcribing, .delivering, .transferred:
            return .active
        case .idle:
            return localRecorder.queuedCount > 0 ? .active : .neutral
        }
    }

    private var statusSymbolName: String {
        switch localRecorder.phase {
        case .recording:
            return "waveform"
        case .paused:
            return "pause.fill"
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

    private var accessibilityStatusLabel: String {
        if localRecorder.isRecording {
            let state = localRecorder.isPaused
                ? String(localized: "paused")
                : String(localized: "recording")
            return String(localized: "Vox.md \(state) at \(formattedDuration(localRecorder.duration)). \(statusSubtitle)")
        }
        return String(localized: "Vox.md Watch status: \(phaseBadgeLabel). \(statusSubtitle)")
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func toggleRecording() async {
        isSending = true
        defer { isSending = false }
        await localRecorder.toggle(using: bridge)
    }

    private func cancelRecording() async {
        isSending = true
        defer { isSending = false }
        localRecorder.cancelRecording()
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

private struct WatchCapturePresetPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var bridge: WatchPhoneBridge
    @EnvironmentObject private var localRecorder: WatchLocalRecorder
    @State private var requestedPresetID: String?
    @State private var isRefreshing = false

    var body: some View {
        ZStack {
            WatchGeist.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: WatchGeist.Spacing.two) {
                    pickerHeader

                    if bridge.snapshot.availablePresets.isEmpty {
                        emptyState
                    } else {
                        ForEach(bridge.snapshot.availablePresets) { preset in
                            presetRow(preset)
                        }
                    }

                    if bridge.snapshot.presetSummariesAreTruncated {
                        Text("More presets are available in Vox.md on iPhone.")
                            .font(WatchGeist.caption())
                            .foregroundStyle(WatchGeist.muted)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, WatchGeist.Spacing.two)
                    }

                    selectionStatus
                }
                .padding(.horizontal, WatchGeist.Spacing.two)
                .padding(.bottom, WatchGeist.Spacing.three)
            }
            .scrollIndicators(.hidden)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            requestedPresetID = bridge.presetSelectionState.pendingPresetID
        }
        .onChange(of: bridge.presetSelectionState) { _, state in
            guard case .idle = state,
                  let requestedPresetID,
                  bridge.snapshot.selectedPresetID == requestedPresetID else { return }
            dismiss()
        }
        .task {
            guard bridge.snapshot.availablePresets.isEmpty else { return }
            await refreshPresets()
        }
    }

    private var pickerHeader: some View {
        HStack(spacing: WatchGeist.Spacing.two) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Capture Preset")
                    .font(WatchGeist.heading(17))
                    .foregroundStyle(WatchGeist.text)
                Text("Used for your next recording")
                    .font(WatchGeist.caption())
                    .foregroundStyle(WatchGeist.muted)
            }
            Spacer(minLength: WatchGeist.Spacing.one)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(WatchGeist.surface)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Capture Preset picker")
        }
        .padding(.horizontal, 2)
        .padding(.vertical, WatchGeist.Spacing.one)
    }

    private func presetRow(_ preset: WatchCapturePresetSummary) -> some View {
        let isSelected = bridge.snapshot.selectedPresetID == preset.id
        let isPending = bridge.presetSelectionState.pendingPresetID == preset.id
        return Button {
            guard !localRecorder.isRecording else { return }
            guard !isSelected else {
                dismiss()
                return
            }
            requestedPresetID = preset.id
            bridge.clearPresetSelectionError()
            bridge.selectPreset(id: preset.id)
        } label: {
            HStack(spacing: WatchGeist.Spacing.two) {
                Image(systemName: preset.symbolName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected || isPending ? WatchGeist.blue : WatchGeist.text)
                    .frame(width: 28, height: 28)
                    .background(isSelected || isPending ? WatchGeist.blueBackground : WatchGeist.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                Text(preset.displayName)
                    .font(WatchGeist.label(.caption))
                    .foregroundStyle(WatchGeist.text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isPending {
                    ProgressView()
                        .controlSize(.small)
                        .tint(WatchGeist.blue)
                        .accessibilityLabel("Waiting for iPhone")
                } else if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(WatchGeist.blue)
                }
            }
            .padding(WatchGeist.Spacing.two)
            .background(WatchGeist.surface)
            .overlay(
                RoundedRectangle(cornerRadius: WatchGeist.Radius.small, style: .continuous)
                    .stroke(isSelected ? WatchGeist.blue.opacity(0.65) : WatchGeist.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: WatchGeist.Radius.small, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: WatchGeist.Radius.small, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(localRecorder.isRecording)
        .opacity(localRecorder.isRecording ? 0.55 : 1)
        .accessibilityLabel(isSelected
                            ? String(localized: "\(preset.displayName) Capture Preset, selected")
                            : String(localized: "\(preset.displayName) Capture Preset"))
        .accessibilityHint(isSelected
                           ? String(localized: "Closes the picker.")
                           : String(localized: "Uses this preset for future Watch recordings."))
    }

    @ViewBuilder
    private var selectionStatus: some View {
        if localRecorder.isRecording {
            Text("Finish the current recording before changing presets.")
                .font(WatchGeist.caption())
                .foregroundStyle(WatchGeist.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, WatchGeist.Spacing.two)
        } else {
            switch bridge.presetSelectionState {
            case .idle:
                EmptyView()
            case .pending:
                Text("Waiting for iPhone. Until confirmed, recordings keep using the selected preset above.")
                    .font(WatchGeist.caption())
                    .foregroundStyle(WatchGeist.muted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, WatchGeist.Spacing.two)
            case .failed(_, let message):
                VStack(spacing: WatchGeist.Spacing.two) {
                    Text(message)
                        .font(WatchGeist.caption())
                        .foregroundStyle(WatchGeist.red)
                        .multilineTextAlignment(.center)
                    Button("Dismiss") {
                        bridge.clearPresetSelectionError()
                    }
                    .buttonStyle(WatchGeistButtonStyle(variant: .secondary))
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: WatchGeist.Spacing.two) {
            Image(systemName: "iphone")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(WatchGeist.muted)
            Text(emptyStateMessage)
                .font(WatchGeist.caption())
                .foregroundStyle(WatchGeist.muted)
                .multilineTextAlignment(.center)
            Button {
                Task { await refreshPresets() }
            } label: {
                HStack(spacing: 6) {
                    if isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text("Refresh")
                }
            }
            .buttonStyle(WatchGeistButtonStyle(variant: .secondary))
            .disabled(isRefreshing)
        }
        .padding(WatchGeist.Spacing.three)
        .frame(maxWidth: .infinity)
        .background(WatchGeist.surface)
        .clipShape(RoundedRectangle(cornerRadius: WatchGeist.Radius.medium, style: .continuous))
    }

    private var emptyStateMessage: String {
        if bridge.snapshot.hasPresetSelectionAvailabilityPayload,
           !bridge.snapshot.presetSelectionIsAvailable {
            return String(localized: "Enable a Capture Preset in Vox.md on iPhone.")
        }
        return String(localized: "Open Vox.md on iPhone to sync your Capture Presets.")
    }

    @MainActor
    private func refreshPresets() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        _ = await bridge.requestStatus()
        isRefreshing = false
    }
}

#Preview {
    WatchRecorderView()
        .environmentObject(WatchPhoneBridge.shared)
        .environmentObject(WatchLocalRecorder())
}
