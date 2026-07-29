import SwiftUI
import VoxboardShared

/// On-device lifetime recording and Capture activity.
struct StatsView: View {
    @Environment(TranscriptStore.self) private var transcriptStore

    @State private var captureRecords: [CaptureHistoryRecord] = []
    @State private var statsLedger: ActivityStatsLedger?
    @State private var statsLoadError: String?
    @State private var referenceDate = Date()

    private let overviewColumns = [
        GridItem(.flexible(), spacing: Geist.Spacing.three),
        GridItem(.flexible(), spacing: Geist.Spacing.three),
    ]

    private var stats: ActivityStats {
        if let statsLedger {
            return ActivityStats(ledger: statsLedger, now: referenceDate)
        }
        return ActivityStats(
            transcripts: transcriptStore.transcripts,
            captureRecords: captureRecords,
            now: referenceDate
        )
    }

    var body: some View {
        ZStack {
            Geist.Palette.background200.ignoresSafeArea()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: Geist.Spacing.six) {
                    overviewSection
                    recentActivitySection

                    if !stats.captureSources.isEmpty {
                        captureSourcesSection
                    }

                    if let statsLoadError {
                        statsErrorCard(statsLoadError)
                    }

                    privacyNote
                }
                .padding(.horizontal, Geist.Spacing.four)
                .padding(.vertical, Geist.Spacing.six)
            }
            .refreshable {
                await reload()
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Stats")
                    .font(Geist.heading(.headline))
                    .foregroundStyle(Geist.text)
            }
        }
        .toolbarBackground(Geist.bg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task {
            await reload()
        }
    }

    // MARK: - Overview

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.three) {
            sectionLabel("Overview")

            LazyVGrid(columns: overviewColumns, spacing: Geist.Spacing.three) {
                statCard(
                    title: "Recordings",
                    value: formattedCount(stats.recordingCount),
                    systemImage: "waveform"
                )
                statCard(
                    title: "Captures",
                    value: formattedCount(stats.captureCount),
                    systemImage: "square.and.arrow.down"
                )
                statCard(
                    title: "Recorded",
                    value: formattedDuration(stats.totalRecordingDuration),
                    systemImage: "clock"
                )
                statCard(
                    title: "Attachments",
                    value: formattedCount(stats.attachmentCount),
                    systemImage: "paperclip"
                )
            }
        }
    }

    private func statCard(title: LocalizedStringKey, value: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.four) {
            HStack {
                Image(systemName: systemImage)
                    .font(.system(.body, weight: .medium))
                    .foregroundStyle(Geist.muted)
                Spacer()
            }

            VStack(alignment: .leading, spacing: Geist.Spacing.one) {
                Text(value)
                    .font(Geist.display(26))
                    .foregroundStyle(Geist.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .contentTransition(.numericText())
                Text(title)
                    .font(Geist.caption())
                    .foregroundStyle(Geist.muted)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
        .geistCard(padding: Geist.Spacing.four)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Recent activity

    private var recentActivitySection: some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.three) {
            HStack(alignment: .firstTextBaseline) {
                sectionLabel("Last 7 Days")
                Spacer()
                Text("\(stats.recentRecordingCount) recordings · \(stats.recentCaptureCount) captures")
                    .font(Geist.caption(.caption2))
                    .foregroundStyle(Geist.muted)
            }

            VStack(alignment: .leading, spacing: Geist.Spacing.four) {
                HStack(alignment: .bottom, spacing: Geist.Spacing.two) {
                    ForEach(stats.recentDays) { day in
                        activityBar(for: day)
                    }
                }

                HStack(spacing: Geist.Spacing.four) {
                    legendItem("Recordings", color: Geist.text)
                    legendItem("Captures", color: Geist.Palette.gray600)
                }
            }
            .geistCard(padding: Geist.Spacing.four)
        }
    }

    private func activityBar(for day: ActivityStats.Day) -> some View {
        let maximum = max(stats.recentDays.map(\.totalCount).max() ?? 0, 1)
        let recordingHeight = segmentHeight(day.recordingCount, maximum: maximum)
        let captureHeight = segmentHeight(day.captureCount, maximum: maximum)

        return VStack(spacing: Geist.Spacing.two) {
            VStack(spacing: 2) {
                Spacer(minLength: 0)
                if day.captureCount > 0 {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Geist.Palette.gray600)
                        .frame(height: captureHeight)
                }
                if day.recordingCount > 0 {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Geist.text)
                        .frame(height: recordingHeight)
                }
                if day.totalCount == 0 {
                    Rectangle()
                        .fill(Geist.Palette.grayAlpha400)
                        .frame(height: 1)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 92)

            Text(day.date, format: .dateTime.weekday(.narrow))
                .font(Geist.mono(.caption2))
                .foregroundStyle(Geist.muted)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(day.date.formatted(date: .complete, time: .omitted))
        .accessibilityValue("\(day.recordingCount) recordings, \(day.captureCount) captures")
    }

    private func segmentHeight(_ count: Int, maximum: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return max(5, CGFloat(count) / CGFloat(maximum) * 84)
    }

    private func legendItem(_ title: LocalizedStringKey, color: Color) -> some View {
        HStack(spacing: Geist.Spacing.two) {
            RoundedRectangle(cornerRadius: 1)
                .fill(color)
                .frame(width: 10, height: 10)
            Text(title)
                .font(Geist.caption(.caption2))
                .foregroundStyle(Geist.muted)
        }
    }

    // MARK: - Capture sources

    private var captureSourcesSection: some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.three) {
            sectionLabel("Capture Sources")

            VStack(spacing: 0) {
                ForEach(Array(stats.captureSources.enumerated()), id: \.element.id) { index, total in
                    captureSourceRow(total)
                    if index < stats.captureSources.count - 1 {
                        GeistDivider()
                    }
                }
            }
            .geistCard(padding: 0)
        }
    }

    private func captureSourceRow(_ total: ActivityStats.CaptureSourceTotal) -> some View {
        HStack(spacing: Geist.Spacing.three) {
            Image(systemName: captureSourceIcon(total.source))
                .font(.system(.body, weight: .medium))
                .foregroundStyle(Geist.text)
                .frame(width: 24)

            Text(captureSourceName(total.source))
                .font(Geist.label())
                .foregroundStyle(Geist.text)

            Spacer()

            Text(formattedCount(total.count))
                .font(Geist.mono(medium: true))
                .foregroundStyle(Geist.muted)
        }
        .padding(.horizontal, Geist.Spacing.four)
        .padding(.vertical, Geist.Spacing.four)
        .accessibilityElement(children: .combine)
    }

    private var privacyNote: some View {
        Label {
            Text("Lifetime totals stay on device. No captured content, filenames, or destinations are stored with stats.")
                .font(Geist.caption(.caption2))
                .foregroundStyle(Geist.muted)
        } icon: {
            Image(systemName: "lock.fill")
                .font(.system(.caption2, weight: .semibold))
                .foregroundStyle(Geist.muted)
        }
        .padding(.horizontal, Geist.Spacing.two)
    }

    private func statsErrorCard(_ message: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: Geist.Spacing.one) {
                Text("Stats temporarily unavailable")
                    .font(Geist.label())
                    .foregroundStyle(Geist.text)
                Text(message)
                    .font(Geist.caption())
                    .foregroundStyle(Geist.muted)
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Geist.error)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .geistCard(padding: Geist.Spacing.four)
    }

    private func sectionLabel(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(Geist.heading(.footnote))
            .foregroundStyle(Geist.text)
    }

    // MARK: - Data

    @MainActor
    private func reload() async {
        transcriptStore.reload()
        referenceDate = Date()

        guard let historyURL = AppConstants.captureHistoryURL,
              let statsURL = AppConstants.activityStatsURL else {
            captureRecords = []
            statsLedger = nil
            statsLoadError = String(localized: "Shared activity storage is unavailable.")
            return
        }

        var loadErrors: [String] = []
        let records: [CaptureHistoryRecord]
        do {
            records = try await CaptureHistoryStore(fileURL: historyURL).list()
        } catch {
            records = []
            loadErrors.append(error.localizedDescription)
        }
        captureRecords = records

        let recordingEvents = transcriptStore.transcripts.map {
            RecordingActivityEvent(id: $0.id, date: $0.date, duration: $0.duration)
        }
        let captureEvents = records.compactMap { record -> CaptureActivityEvent? in
            guard record.outcome == .delivered else { return nil }
            return CaptureActivityEvent(
                id: record.requestID,
                date: record.deliveredAt ?? record.createdAt,
                source: record.source,
                attachmentCount: record.attachmentCount
            )
        }
        do {
            statsLedger = try ActivityStatsStore(fileURL: statsURL).reconcile(
                recordings: recordingEvents,
                captures: captureEvents
            )
        } catch {
            statsLedger = nil
            loadErrors.append(error.localizedDescription)
        }
        statsLoadError = loadErrors.isEmpty ? nil : loadErrors.joined(separator: "\n")
    }

    // MARK: - Formatting

    private func formattedCount(_ count: Int) -> String {
        count.formatted(.number.grouping(.automatic))
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        }

        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        if hours == 0 {
            return "\(minutes)m"
        }
        if minutes == 0 {
            return "\(hours)h"
        }
        return "\(hours)h \(minutes)m"
    }

    private func captureSourceName(_ source: CaptureSource) -> String {
        switch source {
        case .app: return String(localized: "App")
        case .keyboard: return String(localized: "Keyboard")
        case .widget: return String(localized: "Widget")
        case .shortcut: return String(localized: "Shortcut")
        case .shareExtension: return String(localized: "Share")
        case .watch: return String(localized: "Watch")
        case .mac: return String(localized: "Mac")
        case .deepLink: return String(localized: "Deep Link")
        case .fileImport: return String(localized: "File Import")
        case .voice: return String(localized: "Voice")
        }
    }

    private func captureSourceIcon(_ source: CaptureSource) -> String {
        switch source {
        case .app: return "iphone"
        case .keyboard: return "keyboard"
        case .widget: return "square.grid.2x2"
        case .shortcut: return "arrow.turn.down.right"
        case .shareExtension: return "square.and.arrow.up"
        case .watch: return "applewatch"
        case .mac: return "desktopcomputer"
        case .deepLink: return "link"
        case .fileImport: return "doc"
        case .voice: return "waveform"
        }
    }
}
