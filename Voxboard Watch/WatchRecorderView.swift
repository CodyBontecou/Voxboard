import SwiftUI

struct WatchRecorderView: View {
    @EnvironmentObject private var bridge: WatchPhoneBridge
    @EnvironmentObject private var localRecorder: WatchLocalRecorder
    @State private var isSending = false

    var body: some View {
        VStack(spacing: 12) {
            statusHeader

            Button {
                Task { await toggleRecording() }
            } label: {
                Label(localRecorder.actionTitle, systemImage: localRecorder.actionSymbol)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(localRecorder.isRecording ? .red : .green)
            .disabled(isSending)

            Button {
                Task { await syncQueueOrRefreshStatus() }
            } label: {
                Label(localRecorder.syncTitle, systemImage: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .disabled(isSending || localRecorder.isRecording)

            if localRecorder.queuedCount > 0 && !localRecorder.isRecording {
                #if DEBUG
                if !localRecorder.isRunningDemoScript {
                    queueSummary
                }
                #else
                queueSummary
                #endif
            }
        }
        .padding(.horizontal, 4)
        .task {
            bridge.activate()
            try? await Task.sleep(nanoseconds: 750_000_000)
            #if DEBUG
            if localRecorder.runDemoScriptIfNeeded(using: bridge) { return }
            #endif
            localRecorder.syncPending(using: bridge)
        }
    }

    private var queueSummary: some View {
        Text(localRecorder.queueSummary)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .lineLimit(2)
    }

    @ViewBuilder
    private var statusHeader: some View {
        VStack(spacing: 6) {
            Image(systemName: symbolName)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(symbolColor)

            Text(localRecorder.title)
                .font(.headline)
                .multilineTextAlignment(.center)

            if localRecorder.isRecording,
               let startedAt = localRecorder.startedAt {
                Text(startedAt, style: .timer)
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.red)
            } else {
                Text(localRecorder.subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var symbolName: String {
        switch localRecorder.phase {
        case .recording:
            return "waveform.circle.fill"
        case .transferring:
            return "iphone.radiowaves.left.and.right"
        case .transferred:
            return "checkmark.circle.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        case .idle:
            return "mic.circle"
        }
    }

    private var symbolColor: Color {
        switch localRecorder.phase {
        case .recording:
            return .red
        case .transferring:
            return .yellow
        case .transferred:
            return .green
        case .error:
            return .orange
        case .idle:
            return .green
        }
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
