import SwiftUI
import VoxboardShared

struct CaptureDueDateSheet: View {
    var initialDate: Date = Date()
    var onInsert: (Date, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @State private var selectedDate: Date
    @State private var includesTime = false

    init(initialDate: Date = Date(), onInsert: @escaping (Date, Bool) -> Void) {
        self.initialDate = initialDate
        self.onInsert = onInsert
        _selectedDate = State(initialValue: initialDate)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    quickDates

                    DatePicker(
                        "Due date",
                        selection: $selectedDate,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .padding(10)
                    .background(Brutal.surface)
                    .overlay(Rectangle().stroke(Brutal.borderHi, lineWidth: 1))

                    VStack(spacing: 12) {
                        Toggle(isOn: $includesTime) {
                            Label("Time", systemImage: "clock")
                                .font(Brutal.body())
                        }
                        .tint(Brutal.text)

                        if includesTime {
                            DatePicker(
                                "Time",
                                selection: $selectedDate,
                                displayedComponents: .hourAndMinute
                            )
                            .datePickerStyle(.compact)

                            timeAdjustments
                        }
                    }
                    .padding(14)
                    .background(Brutal.surface)
                    .overlay(Rectangle().stroke(Brutal.borderHi, lineWidth: 1))

                    Button {
                        onInsert(selectedDate, includesTime)
                        dismiss()
                    } label: {
                        Label(insertLabel, systemImage: "calendar.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(BrutalButtonStyle(variant: .primary))
                    .accessibilityIdentifier("capture_due_date_insert")
                }
                .padding(16)
            }
            .background(Brutal.bg.ignoresSafeArea())
            .navigationTitle("Set due date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    private var quickDates: some View {
        HStack(spacing: 8) {
            quickDateButton("Today", date: startOfToday)
            quickDateButton("Tomorrow", date: insertionFormatter.applying(.tomorrow, to: startOfToday))
            quickDateButton("This Weekend", date: insertionFormatter.applying(.thisWeekend, to: startOfToday))
        }
    }

    private func quickDateButton(_ title: LocalizedStringKey, date: Date) -> some View {
        Button {
            selectedDate = mergingTime(from: selectedDate, into: date)
        } label: {
            VStack(spacing: 3) {
                Text(title)
                    .font(Brutal.caption())
                Text(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .font(.caption2.monospaced())
                    .foregroundStyle(Brutal.muted)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(BrutalButtonStyle(variant: .secondary))
    }

    private var timeAdjustments: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                adjustmentButton("+15m", minutes: 15)
                adjustmentButton("+30m", minutes: 30)
                adjustmentButton("+1h", minutes: 60)
                adjustmentButton("−15m", minutes: -15)
                adjustmentButton("−30m", minutes: -30)
                adjustmentButton("−1h", minutes: -60)
            }
        }
        .accessibilityLabel("Adjust due time")
    }

    private func adjustmentButton(_ title: String, minutes: Int) -> some View {
        Button(title) {
            selectedDate = insertionFormatter.adjusting(selectedDate, by: minutes, unit: .minute)
        }
        .font(Brutal.caption())
        .buttonStyle(BrutalButtonStyle(variant: .secondary))
        .accessibilityLabel("Adjust due time by \(title)")
    }

    private var insertLabel: String {
        if includesTime {
            return selectedDate.formatted(
                .dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute().locale(locale)
            )
        }
        return selectedDate.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).locale(locale))
    }

    private var startOfToday: Date { calendar.startOfDay(for: Date()) }

    private var insertionFormatter: CaptureInsertionFormatter {
        CaptureInsertionFormatter(calendar: calendar, locale: locale, timeZone: timeZone)
    }

    private func mergingTime(from source: Date, into day: Date) -> Date {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: source)
        return calendar.date(
            bySettingHour: parts.hour ?? 9,
            minute: parts.minute ?? 0,
            second: 0,
            of: day
        ) ?? day
    }
}
