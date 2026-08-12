import Foundation

/// The paid access granted to this installation and its shared app extensions.
public enum VoxboardAccessLevel: String, Codable, CaseIterable, Sendable {
    case free
    case individual
    case family

    public var hasUnlimitedAccess: Bool {
        self != .free
    }

    public var includesFamilySharing: Bool {
        self == .family
    }

    static func highest(_ lhs: Self, _ rhs: Self) -> Self {
        rank(lhs) >= rank(rhs) ? lhs : rhs
    }

    private static func rank(_ level: Self) -> Int {
        switch level {
        case .free: 0
        case .individual: 1
        case .family: 2
        }
    }
}

/// Store products that can grant Vox.md Unlimited access.
public enum VoxboardPurchaseProduct: String, CaseIterable, Sendable {
    /// The original individual lifetime unlock.
    case individual = "bontecou.Voxboard.unlock"
    /// A direct lifetime unlock that supports Apple's Family Sharing.
    case family = "bontecou.Voxboard.family"
    /// The discounted Family Sharing upgrade for existing individual owners.
    case familyUpgrade = "bontecou.Voxboard.familyUpgrade"

    public var grantedAccessLevel: VoxboardAccessLevel {
        switch self {
        case .individual:
            .individual
        case .family, .familyUpgrade:
            .family
        }
    }

    /// Products the app should present for the current access level.
    public static func purchaseOptions(for accessLevel: VoxboardAccessLevel) -> [Self] {
        switch accessLevel {
        case .free:
            [.individual, .family]
        case .individual:
            [.familyUpgrade]
        case .family:
            []
        }
    }

    public static func strongest(in products: some Sequence<Self>) -> Self? {
        products.max { productPriority($0) < productPriority($1) }
    }

    private static func productPriority(_ product: Self) -> Int {
        switch product {
        case .individual: 1
        case .familyUpgrade: 2
        case .family: 3
        }
    }
}

/// Privacy-safe StoreKit evidence retained for support diagnostics. It never
/// contains an Apple Account identifier, transaction identifier, or purchase date.
public struct PurchaseEntitlementObservation: Codable, Equatable, Sendable {
    public var productID: String
    public var isVerified: Bool
    public var isRecognized: Bool
    public var isRevoked: Bool
    public var isUpgraded: Bool
    public var ownershipType: String
    public var environment: String
    public var verificationError: String?

    public init(
        productID: String,
        isVerified: Bool,
        isRecognized: Bool,
        isRevoked: Bool,
        isUpgraded: Bool,
        ownershipType: String,
        environment: String,
        verificationError: String? = nil
    ) {
        self.productID = productID
        self.isVerified = isVerified
        self.isRecognized = isRecognized
        self.isRevoked = isRevoked
        self.isUpgraded = isUpgraded
        self.ownershipType = ownershipType
        self.environment = environment
        self.verificationError = verificationError
    }
}

public struct PurchaseRestoreDiagnostics: Codable, Equatable, Sendable {
    public var platform: String
    public var syncSucceeded: Bool
    public var syncError: String?
    public var requestedProductIDs: [String]
    public var loadedProductIDs: [String]
    public var storefrontCountryCode: String?
    public var observations: [PurchaseEntitlementObservation]

    public init(
        platform: String,
        syncSucceeded: Bool,
        syncError: String? = nil,
        requestedProductIDs: [String],
        loadedProductIDs: [String],
        storefrontCountryCode: String? = nil,
        observations: [PurchaseEntitlementObservation]
    ) {
        self.platform = platform
        self.syncSucceeded = syncSucceeded
        self.syncError = syncError
        self.requestedProductIDs = requestedProductIDs.sorted()
        self.loadedProductIDs = loadedProductIDs.sorted()
        self.storefrontCountryCode = storefrontCountryCode
        self.observations = observations.sorted { lhs, rhs in
            if lhs.productID == rhs.productID {
                return lhs.ownershipType < rhs.ownershipType
            }
            return lhs.productID < rhs.productID
        }
    }

    public var summary: String {
        let entitlementSummary = observations.map { observation in
            [
                observation.productID,
                observation.isVerified ? "verified" : "unverified",
                observation.isRecognized ? "recognized" : "unknown",
                observation.isRevoked ? "revoked" : "active",
                observation.isUpgraded ? "upgraded" : "current",
                observation.ownershipType,
                observation.environment,
                observation.verificationError.map { "error=\($0)" },
            ]
            .compactMap { $0 }
            .joined(separator: ",")
        }
        return [
            "platform=\(platform)",
            "sync=\(syncSucceeded ? "success" : "failure")",
            syncError.map { "syncError=\($0)" },
            "storefront=\(storefrontCountryCode ?? "unknown")",
            "requested=[\(requestedProductIDs.joined(separator: ","))]",
            "loaded=[\(loadedProductIDs.joined(separator: ","))]",
            "entitlements=[\(entitlementSummary.joined(separator: ";"))]",
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }
}
