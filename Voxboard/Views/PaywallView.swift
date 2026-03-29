import SwiftUI
import VoxboardShared

/// Full-screen paywall shown when the user has consumed their 15 free minutes.
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(UsageTracker.self) private var usageTracker
    @Environment(StoreManager.self) private var storeManager

    var body: some View {
        ZStack {
            Brutal.bg.ignoresSafeArea()
            BrutalGridBackground().ignoresSafeArea().allowsHitTesting(false)

            VStack(spacing: 0) {
                header
                BrutalDivider()
                ScrollView {
                    VStack(spacing: 0) {
                        usageSection
                        BrutalDivider()
                        unlockSection
                        BrutalDivider()
                        featuresSection
                        BrutalDivider()
                        restoreSection
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await storeManager.loadProducts() }
    }

    private var statusBadgeLabel: String {
        if usageTracker.hasUnlocked { return "Unlimited" }
        return usageTracker.isAtLimit ? "Limit Reached" : "Free Tier"
    }

    private var usageStatusMessage: String {
        if usageTracker.hasUnlocked {
            return "Unlimited is already unlocked on this device."
        }
        if usageTracker.isAtLimit {
            return "You've used all your free transcription time."
        }
        return String(format: "%.1f min free remaining.", max(0, UsageTracker.freeMinutesLimit - usageTracker.minutesUsed))
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            BrutalStatusBadge(label: statusBadgeLabel, isActive: !usageTracker.isAtLimit)
            Spacer()
            Text("VOXBOARD")
                .font(Brutal.label(13))
                .foregroundColor(Brutal.text)
            Spacer()
            Button(action: { dismiss() }) {
                Text("✕")
                    .font(Brutal.label(14))
                    .foregroundColor(Brutal.faint)
                    .frame(width: 34, height: 34)
                    .overlay(Rectangle().stroke(Brutal.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Usage Section

    private var usageSection: some View {
        VStack(spacing: 20) {
            HStack {
                BrutalSectionLabel(number: "01", title: "Usage")
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)

            // Big usage display
            VStack(spacing: 8) {
                Text("FREE TIER")
                    .font(Brutal.caption(10))
                    .foregroundColor(Brutal.faint)
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text(String(format: "%.1f", min(usageTracker.minutesUsed, 15.0)))
                        .font(Brutal.display(52))
                        .foregroundColor(Brutal.text)
                        .monospacedDigit()
                    Text("/ 15 MIN")
                        .font(Brutal.label(14))
                        .foregroundColor(Brutal.muted)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            }
            .padding(.horizontal, 20)

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Brutal.surface)
                        .frame(height: 4)
                        .overlay(Rectangle().stroke(Brutal.border, lineWidth: 1))

                    Rectangle()
                        .fill(Brutal.text)
                        .frame(width: geo.size.width * usageTracker.fractionUsed, height: 4)
                }
            }
            .frame(height: 4)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            Text(usageStatusMessage)
                .font(Brutal.body(12))
                .foregroundColor(usageTracker.isAtLimit ? Brutal.error : Brutal.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
        }
    }

    // MARK: - Unlock Section

    private var unlockSection: some View {
        VStack(spacing: 0) {
            HStack {
                BrutalSectionLabel(number: "02", title: "Unlock")
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 20)

            // Price callout
            VStack(spacing: 6) {
                Text("ONE-TIME PURCHASE")
                    .font(Brutal.caption(10))
                    .foregroundColor(Brutal.faint)
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text(storeManager.displayPrice)
                        .font(Brutal.display(48))
                        .foregroundColor(Brutal.text)
                    Text("forever")
                        .font(Brutal.body(13))
                        .foregroundColor(Brutal.muted)
                }
                Text("No subscription. No renewal. Pay once.")
                    .font(Brutal.caption(10))
                    .foregroundColor(Brutal.faint)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)

            // Buy button
            Button(action: {
                Task { await storeManager.purchase() }
            }) {
                Group {
                    if storeManager.isPurchasing {
                        HStack(spacing: 10) {
                            ProgressView()
                                .scaleEffect(0.8)
                                .tint(Brutal.bg)
                            Text("PURCHASING…")
                        }
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "lock.open.fill").font(.system(size: 11))
                            Text("UNLOCK UNLIMITED — \(storeManager.displayPrice)")
                        }
                    }
                }
            }
            .buttonStyle(BrutalButtonStyle(variant: .primary))
            .disabled(storeManager.isPurchasing || storeManager.product == nil)
            .padding(.horizontal, 20)

            if let error = storeManager.errorMessage {
                Text(error)
                    .font(Brutal.caption(10))
                    .foregroundColor(Brutal.error)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
            }

            Spacer(minLength: 24)
        }
    }

    // MARK: - Features Section

    private var featuresSection: some View {
        VStack(spacing: 0) {
            HStack {
                BrutalSectionLabel(number: "03", title: "What you get")
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 16)

            let features: [(String, String)] = [
                ("Unlimited transcription", "No time caps, ever"),
                ("On-device processing",    "Zero data leaves your phone"),
                ("All models included",     "Tiny, Base, Small, and more"),
                ("Keyboard integration",    "Works in any app"),
                ("Lifetime access",         "Pay once, use forever"),
            ]

            ForEach(features, id: \.0) { title, detail in
                HStack(spacing: 14) {
                    Rectangle()
                        .fill(Brutal.text)
                        .frame(width: 4, height: 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title.uppercased())
                            .font(Brutal.label(12))
                            .foregroundColor(Brutal.text)
                        Text(detail)
                            .font(Brutal.caption(10))
                            .foregroundColor(Brutal.faint)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                BrutalDivider()
            }
        }
    }

    // MARK: - Restore Section

    private var restoreSection: some View {
        VStack(spacing: 16) {
            Button(action: {
                Task { await storeManager.restorePurchases() }
            }) {
                Group {
                    if storeManager.isRestoring {
                        HStack(spacing: 10) {
                            ProgressView()
                                .scaleEffect(0.8)
                                .tint(Brutal.text)
                            Text("RESTORING…")
                        }
                    } else {
                        Text("RESTORE PREVIOUS PURCHASE")
                    }
                }
            }
            .buttonStyle(BrutalButtonStyle(variant: .secondary))
            .disabled(storeManager.isRestoring)
            .padding(.horizontal, 20)

            Text("Already purchased? Tap to restore your purchase. No charge will be made.")
                .font(Brutal.caption(10))
                .foregroundColor(Brutal.faint)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Spacer(minLength: 40)
        }
        .padding(.top, 24)
    }
}
