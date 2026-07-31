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
