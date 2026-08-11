import SwiftUI
import VoxboardShared

/// Lifetime purchase screen shown from usage limits and Settings.
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
                    if !usageTracker.hasUnlocked {
                        usageCard
                    }
                    purchaseSection
                    if let error = storeManager.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(Geist.caption())
                            .foregroundStyle(Geist.error)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
        .task { await storeManager.prepareForPurchases() }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.three) {
            GeistStatusBadge(label: statusBadgeLabel, isActive: usageTracker.hasUnlocked)

            Text(heroTitle)
                .font(Geist.heading(.largeTitle))
                .tracking(-1.28)
                .foregroundStyle(Geist.text)

            Text(heroDetail)
                .font(Geist.body())
                .foregroundStyle(Geist.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var usageCard: some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.four) {
            Text("Free Usage")
                .font(Geist.heading(.headline))
                .foregroundStyle(Geist.text)

            quotaMeter(
                title: "Transcription",
                value: String(
                    format: String(localized: "%.1f / 15 min"),
                    locale: Locale.current,
                    min(usageTracker.minutesUsed, 15)
                ),
                progress: usageTracker.fractionUsed,
                isAtLimit: usageTracker.isAtLimit
            )

            GeistDivider()

            quotaMeter(
                title: "Capture",
                value: "\(min(usageTracker.successfulCapturesUsed, UsageTracker.freeCaptureLimit)) / \(UsageTracker.freeCaptureLimit)",
                progress: usageTracker.captureFractionUsed,
                isAtLimit: usageTracker.isCaptureAtLimit
            )

            Text(usageStatusMessage)
                .font(Geist.caption())
                .foregroundStyle(
                    usageTracker.isAtLimit || usageTracker.isCaptureAtLimit ? Geist.error : Geist.muted
                )
        }
        .geistCard(padding: Geist.Spacing.four)
    }

    private func quotaMeter(
        title: LocalizedStringKey,
        value: String,
        progress: Double,
        isAtLimit: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.two) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(Geist.label())
                    .foregroundStyle(Geist.text)
                Spacer()
                Text(value)
                    .font(Geist.mono(.footnote, medium: true))
                    .foregroundStyle(Geist.muted)
            }
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(isAtLimit ? Geist.Palette.red800 : Geist.Palette.blue700)
        }
    }

    @ViewBuilder
    private var purchaseSection: some View {
        if !storeManager.isEntitlementStateReady {
            HStack(spacing: Geist.Spacing.three) {
                ProgressView()
                Text("Checking Purchases…")
                    .font(Geist.body())
                    .foregroundStyle(Geist.muted)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .geistCard()
        } else {
            purchaseOptions
        }
    }

    @ViewBuilder
    private var purchaseOptions: some View {
        switch usageTracker.accessLevel {
        case .free:
            VStack(alignment: .leading, spacing: Geist.Spacing.four) {
                VStack(alignment: .leading, spacing: Geist.Spacing.one) {
                    Text("Choose Lifetime Access")
                        .font(Geist.heading(.headline))
                        .foregroundStyle(Geist.text)
                    Text("Pay once. No subscription or renewal.")
                        .font(Geist.caption())
                        .foregroundStyle(Geist.muted)
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 260), spacing: Geist.Spacing.four)],
                    alignment: .leading,
                    spacing: Geist.Spacing.four
                ) {
                    offerCard(
                        product: .individual,
                        title: "Individual Unlimited",
                        detail: "Unlimited Capture and transcription on devices signed in to your Apple Account.",
                        buttonTitle: "Unlock Individual"
                    )
                    offerCard(
                        product: .family,
                        title: "Family Unlimited",
                        detail: "Unlimited access you can share with your Apple Family Sharing group.",
                        buttonTitle: "Unlock Family",
                        badge: "FAMILY"
                    )
                }
            }

        case .individual:
            offerCard(
                product: .familyUpgrade,
                title: "Upgrade to Family",
                detail: "Add Apple Family Sharing to your existing lifetime Unlimited purchase.",
                buttonTitle: "Upgrade to Family",
                badge: "EXISTING OWNER PRICE"
            )

        case .family:
            VStack(alignment: .leading, spacing: Geist.Spacing.three) {
                Label("Family Unlimited Is Unlocked", systemImage: "person.3.fill")
                    .font(Geist.heading(.headline))
                    .foregroundStyle(Geist.text)
                Text("Your lifetime Unlimited access supports Apple Family Sharing.")
                    .font(Geist.body())
                    .foregroundStyle(Geist.muted)
            }
            .geistCard()
        }
    }

    private func offerCard(
        product: VoxboardPurchaseProduct,
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        buttonTitle: LocalizedStringKey,
        badge: LocalizedStringKey? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.four) {
            VStack(alignment: .leading, spacing: Geist.Spacing.two) {
                if let badge {
                    Text(badge)
                        .font(Geist.mono(.caption2, medium: true))
                        .foregroundStyle(Geist.Palette.blue900)
                }
                Text(title)
                    .font(Geist.heading(.headline))
                    .foregroundStyle(Geist.text)
                HStack(alignment: .lastTextBaseline, spacing: Geist.Spacing.two) {
                    Text(storeManager.displayPrice(for: product) ?? String(localized: "Price unavailable"))
                        .font(Geist.heading(.title))
                        .foregroundStyle(Geist.text)
                    Text("one time")
                        .font(Geist.caption())
                        .foregroundStyle(Geist.muted)
                }
                Text(detail)
                    .font(Geist.caption())
                    .foregroundStyle(Geist.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Button {
                Task { await storeManager.purchase(product, context: context) }
            } label: {
                HStack(spacing: Geist.Spacing.two) {
                    if storeManager.purchasingProductID == product.rawValue {
                        ProgressView().tint(Geist.Palette.background100)
                        Text("Purchasing…")
                    } else {
                        Image(systemName: product == .individual ? "person.fill" : "person.3.fill")
                        Text(buttonTitle)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(GeistButtonStyle(variant: .primary))
            .disabled(storeManager.isPurchasing || storeManager.product(for: product) == nil)
        }
        .geistCard()
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: Geist.Spacing.three) {
            Text("Included")
                .font(Geist.heading(.headline))
                .foregroundStyle(Geist.text)

            VStack(spacing: 0) {
                featureRow("Unlimited Capture", detail: "Send as many local notes as you like", icon: "square.and.pencil")
                GeistDivider()
                featureRow("Unlimited Transcription", detail: "No time caps", icon: "infinity")
                GeistDivider()
                featureRow("On-Device Processing", detail: "Voice data stays on your device", icon: "lock.shield")
                GeistDivider()
                featureRow("All Models", detail: "Use every supported local model", icon: "cpu")
                GeistDivider()
                featureRow("Family Sharing", detail: "Included with Family Unlimited", icon: "person.3")
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
                        Text("Restore Purchases")
                    }
                }
            }
            .buttonStyle(GeistButtonStyle(variant: .secondary))
            .disabled(storeManager.isRestoring || storeManager.isPurchasing)

            Text("Restore purchases or Family Sharing access from your Apple Account.")
                .font(Geist.caption())
                .foregroundStyle(Geist.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var statusBadgeLabel: LocalizedStringKey {
        switch usageTracker.accessLevel {
        case .family: "Family Unlimited"
        case .individual: "Individual Unlimited"
        case .free:
            if usageTracker.isAtLimit || usageTracker.isCaptureAtLimit {
                "Limit Reached"
            } else {
                "Free Tier"
            }
        }
    }

    private var heroTitle: LocalizedStringKey {
        switch usageTracker.accessLevel {
        case .family: "Family Unlimited Is Unlocked"
        case .individual: "Unlimited Is Unlocked"
        case .free: "Capture and Transcribe Without Limits"
        }
    }

    private var heroDetail: LocalizedStringKey {
        switch usageTracker.accessLevel {
        case .family:
            "Your lifetime purchase includes Unlimited access and Apple Family Sharing."
        case .individual:
            "You have lifetime Unlimited access. Upgrade once to share it with your Family Sharing group."
        case .free:
            "Choose individual or Family lifetime access for unlimited local Capture and private, on-device transcription."
        }
    }

    private var usageStatusMessage: String {
        if usageTracker.isAtLimit && usageTracker.isCaptureAtLimit {
            return String(localized: "Your free transcription time and captures are used. Unlock Unlimited to continue.")
        }
        if usageTracker.isCaptureAtLimit {
            return String(localized: "Your free captures are used. Unlock Unlimited to keep capturing.")
        }
        if usageTracker.isAtLimit {
            return String(localized: "Free transcription time is used. Unlock Unlimited to keep recording.")
        }
        let remainingMinutes = max(0, UsageTracker.freeMinutesLimit - usageTracker.minutesUsed)
        return String(
            format: String(localized: "%.1f min and %d captures free remaining"),
            remainingMinutes,
            usageTracker.capturesRemaining
        )
    }
}
