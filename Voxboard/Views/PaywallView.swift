import SwiftUI
import VoxboardShared

/// One-time purchase screen shown from usage limits and Settings.
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(UsageTracker.self) private var usageTracker
    @Environment(StoreManager.self) private var storeManager

    let context: OnboardingAnalyticsPaywallContext

    init(context: OnboardingAnalyticsPaywallContext = .limit) {
        self.context = context
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Geist.Spacing.eight) {
                    hero
                    usageCard
                    purchaseCard
                    features
                    restorePurchases
                }
                .padding(.horizontal, Geist.Spacing.four)
                .padding(.vertical, Geist.Spacing.six)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .background(Geist.Palette.background200.ignoresSafeArea())
            .navigationTitle("Vox.md Unlimited")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                        .font(Geist.label())
                        .foregroundStyle(Geist.text)
                }
            }
            .toolbarBackground(Geist.Palette.background100, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .onAppear {
            OnboardingAnalyticsClient.shared.trackPaywallShown(
                context: context,
                quotaState: usageTracker.onboardingAnalyticsQuotaState
            )
        }
        .task { await storeManager.loadProducts() }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.three) {
            GeistStatusBadge(label: statusBadgeLabel, isActive: usageTracker.hasUnlocked)

            Text(usageTracker.hasUnlocked ? "Unlimited Is Unlocked" : "Transcribe Without Limits")
                .font(Geist.heading(.largeTitle))
                .tracking(-1.28)
                .foregroundStyle(Geist.text)

            Text("One purchase unlocks unlimited, private, on-device transcription across Vox.md.")
                .font(Geist.body())
                .foregroundStyle(Geist.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var usageCard: some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.four) {
            HStack(alignment: .firstTextBaseline) {
                Text("Free Usage")
                    .font(Geist.heading(.headline))
                    .foregroundStyle(Geist.text)
                Spacer()
                Text(String(format: "%.1f / 15 min", min(usageTracker.minutesUsed, 15)))
                    .font(Geist.mono(.footnote, medium: true))
                    .foregroundStyle(Geist.muted)
            }

            ProgressView(value: usageTracker.fractionUsed)
                .progressViewStyle(.linear)
                .tint(usageTracker.isAtLimit ? Geist.Palette.red800 : Geist.Palette.blue700)

            Text(usageStatusMessage)
                .font(Geist.caption())
                .foregroundStyle(usageTracker.isAtLimit ? Geist.error : Geist.muted)
        }
        .geistCard(padding: Geist.Spacing.four)
    }

    private var purchaseCard: some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.six) {
            VStack(alignment: .leading, spacing: Geist.Spacing.two) {
                Text("Lifetime Access")
                    .font(Geist.heading(.headline))
                    .foregroundStyle(Geist.text)
                HStack(alignment: .lastTextBaseline, spacing: Geist.Spacing.two) {
                    Text(storeManager.displayPrice)
                        .font(Geist.heading(.largeTitle))
                        .tracking(-1.28)
                        .foregroundStyle(Geist.text)
                    Text("one time")
                        .font(Geist.body())
                        .foregroundStyle(Geist.muted)
                }
                Text("No subscription or renewal.")
                    .font(Geist.caption())
                    .foregroundStyle(Geist.muted)
            }

            Button {
                Task { await storeManager.purchase(context: context) }
            } label: {
                HStack(spacing: Geist.Spacing.two) {
                    if storeManager.isPurchasing {
                        ProgressView().tint(Geist.Palette.background100)
                        Text("Purchasing…")
                    } else {
                        Image(systemName: "lock.open.fill")
                        Text("Unlock Unlimited")
                    }
                }
            }
            .buttonStyle(GeistButtonStyle(variant: .primary))
            .disabled(storeManager.isPurchasing || storeManager.product == nil || usageTracker.hasUnlocked)

            if let error = storeManager.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(Geist.caption())
                    .foregroundStyle(Geist.error)
            }
        }
        .geistCard()
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.three) {
            Text("Included")
                .font(Geist.heading(.headline))
                .foregroundStyle(Geist.text)

            VStack(spacing: 0) {
                featureRow("Unlimited Transcription", detail: "No time caps", icon: "infinity")
                GeistDivider()
                featureRow("On-Device Processing", detail: "Voice data stays on your device", icon: "lock.shield")
                GeistDivider()
                featureRow("All Models", detail: "Use every supported local model", icon: "cpu")
                GeistDivider()
                featureRow("Keyboard Integration", detail: "Transcribe from other apps", icon: "keyboard")
                GeistDivider()
                featureRow("Lifetime Access", detail: "Pay once and keep it", icon: "checkmark.seal")
            }
            .background(Geist.Palette.background100)
            .overlay(
                RoundedRectangle(cornerRadius: Geist.Radius.medium, style: .continuous)
                    .stroke(Geist.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Geist.Radius.medium, style: .continuous))
        }
    }

    private func featureRow(_ title: LocalizedStringKey, detail: LocalizedStringKey, icon: String) -> some View {
        HStack(spacing: Geist.Spacing.three) {
            Image(systemName: icon)
                .foregroundStyle(Geist.Palette.blue900)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: Geist.Spacing.one) {
                Text(title)
                    .font(Geist.label())
                    .foregroundStyle(Geist.text)
                Text(detail)
                    .font(Geist.caption())
                    .foregroundStyle(Geist.muted)
            }
            Spacer()
        }
        .padding(Geist.Spacing.four)
    }

    private var restorePurchases: some View {
        VStack(spacing: Geist.Spacing.three) {
            Button {
                Task { await storeManager.restorePurchases(context: .restore) }
            } label: {
                HStack(spacing: Geist.Spacing.two) {
                    if storeManager.isRestoring {
                        ProgressView()
                        Text("Restoring…")
                    } else {
                        Text("Restore Purchase")
                    }
                }
            }
            .buttonStyle(GeistButtonStyle(variant: .secondary))
            .disabled(storeManager.isRestoring)

            Text("Restore a previous purchase made with your Apple Account.")
                .font(Geist.caption())
                .foregroundStyle(Geist.muted)
                .multilineTextAlignment(.center)
        }
    }

    private var statusBadgeLabel: LocalizedStringKey {
        if usageTracker.hasUnlocked { return "Unlimited" }
        return usageTracker.isAtLimit ? "Limit Reached" : "Free Tier"
    }

    private var usageStatusMessage: String {
        if usageTracker.hasUnlocked {
            return String(localized: "Unlimited is unlocked on this device.")
        }
        if usageTracker.isAtLimit {
            return String(localized: "Free transcription time is used. Unlock Unlimited to keep recording.")
        }
        let remaining = max(0, UsageTracker.freeMinutesLimit - usageTracker.minutesUsed)
        return String(format: String(localized: "%.1f min free remaining"), remaining)
    }
}
