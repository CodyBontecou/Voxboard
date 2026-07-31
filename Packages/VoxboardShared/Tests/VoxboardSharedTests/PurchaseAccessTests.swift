import XCTest
@testable import VoxboardShared

final class PurchaseAccessTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "PurchaseAccessTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testNewUserStartsFreeAndSeesIndividualAndFamilyProducts() {
        let tracker = UsageTracker(defaults: defaults)

        XCTAssertEqual(tracker.accessLevel, .free)
        XCTAssertFalse(tracker.hasUnlocked)
        XCTAssertEqual(
            VoxboardPurchaseProduct.purchaseOptions(for: tracker.accessLevel),
            [.individual, .family]
        )
    }

    func testLegacyUnlockedBooleanRemainsProvisionalUntilClassified() {
        defaults.set(true, forKey: UsageTracker.hasUnlockedKey)

        let tracker = UsageTracker(defaults: defaults)
        tracker.reconcileStoreEntitlements([])

        XCTAssertEqual(tracker.accessLevel, .individual)
        XCTAssertTrue(tracker.isLegacyAccessClassificationPending)
        XCTAssertFalse(tracker.isEligibleForFamilyUpgrade)
        XCTAssertTrue(tracker.purchaseOptions.isEmpty)

        tracker.completeLegacyAccessClassification(isOriginalPaidAppOwner: false)
        tracker.reconcileStoreEntitlements([])

        XCTAssertEqual(tracker.accessLevel, .free)
        XCTAssertFalse(tracker.hasUnlocked)
    }

    func testConfirmedPaidAppOwnerKeepsPermanentIndividualAccess() {
        defaults.set(true, forKey: UsageTracker.hasUnlockedKey)
        let tracker = UsageTracker(defaults: defaults)

        tracker.completeLegacyAccessClassification(isOriginalPaidAppOwner: true)
        tracker.reconcileStoreEntitlements([])
        tracker.addUsage(seconds: UsageTracker.freeMinutesLimit * 60 + 1)

        XCTAssertEqual(tracker.accessLevel, .individual)
        XCTAssertFalse(tracker.isLegacyAccessClassificationPending)
        XCTAssertTrue(tracker.isEligibleForFamilyUpgrade)
        XCTAssertFalse(tracker.isAtLimit)
    }

    func testVerifiedIndividualEntitlementQualifiesWhileLegacyClassificationIsPending() {
        defaults.set(true, forKey: UsageTracker.hasUnlockedKey)
        let tracker = UsageTracker(defaults: defaults)

        tracker.reconcileStoreEntitlements([.individual])

        XCTAssertTrue(tracker.isLegacyAccessClassificationPending)
        XCTAssertTrue(tracker.hasCurrentIndividualStoreEntitlement)
        XCTAssertTrue(tracker.isEligibleForFamilyUpgrade)
        XCTAssertEqual(tracker.purchaseOptions, [.familyUpgrade])
    }

    func testLegacyStoreKitOwnerLosesAccessAfterEntitlementRevocation() {
        defaults.set(true, forKey: UsageTracker.hasUnlockedKey)
        let tracker = UsageTracker(defaults: defaults)

        tracker.completeLegacyAccessClassification(isOriginalPaidAppOwner: false)
        tracker.reconcileStoreEntitlements([.individual])
        XCTAssertEqual(tracker.accessLevel, .individual)

        tracker.reconcileStoreEntitlements([])
        XCTAssertEqual(tracker.accessLevel, .free)
        XCTAssertFalse(tracker.hasCurrentIndividualStoreEntitlement)
        XCTAssertFalse(tracker.isEligibleForFamilyUpgrade)
    }

    func testVerifiedFamilyPurchasePersistsAndCanBeReconciledAway() {
        var tracker: UsageTracker? = UsageTracker(defaults: defaults)
        tracker?.applyVerifiedPurchase(.family)

        tracker = UsageTracker(defaults: defaults)
        XCTAssertEqual(tracker?.accessLevel, .family)
        XCTAssertTrue(tracker?.hasFamilyAccess == true)

        tracker?.reconcileStoreEntitlements([])
        XCTAssertEqual(tracker?.accessLevel, .free)
        XCTAssertFalse(tracker?.hasUnlocked == true)
    }

    func testFamilyUpgradeAloneGrantsFamilyAccess() {
        let tracker = UsageTracker(defaults: defaults)

        tracker.reconcileStoreEntitlements([.familyUpgrade])

        XCTAssertEqual(tracker.accessLevel, .family)
        XCTAssertTrue(tracker.hasFamilyAccess)
        XCTAssertTrue(VoxboardPurchaseProduct.purchaseOptions(for: tracker.accessLevel).isEmpty)
    }

    func testFamilyEntitlementWinsThenDowngradesToIndividual() {
        let tracker = UsageTracker(defaults: defaults)

        tracker.reconcileStoreEntitlements([.individual, .family])
        XCTAssertEqual(tracker.accessLevel, .family)

        tracker.reconcileStoreEntitlements([.individual])
        XCTAssertEqual(tracker.accessLevel, .individual)
    }

    func testProductIdentifiersAndAnalyticsMappingRemainAligned() {
        XCTAssertEqual(VoxboardPurchaseProduct.individual.rawValue, "bontecou.Voxboard.unlock")
        XCTAssertEqual(VoxboardPurchaseProduct.family.rawValue, "bontecou.Voxboard.family")
        XCTAssertEqual(VoxboardPurchaseProduct.familyUpgrade.rawValue, "bontecou.Voxboard.familyUpgrade")
        XCTAssertEqual(OnboardingAnalyticsProductID(.individual), .lifetimeUnlock)
        XCTAssertEqual(OnboardingAnalyticsProductID(.family), .familyUnlock)
        XCTAssertEqual(OnboardingAnalyticsProductID(.familyUpgrade), .familyUpgrade)
    }

    func testStrongestProductSelectionIsDeterministic() {
        XCTAssertEqual(
            VoxboardPurchaseProduct.strongest(in: [.individual, .familyUpgrade]),
            .familyUpgrade
        )
        XCTAssertEqual(
            VoxboardPurchaseProduct.strongest(in: [.familyUpgrade, .family]),
            .family
        )
    }
}
