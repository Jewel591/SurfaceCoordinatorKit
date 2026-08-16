import Foundation

/// Semantic class of an app-initiated surface, used by cross-surface rules
/// (category cooldowns, forbidden successions).
///
/// Categories are host-defined vocabulary, not a fixed enum: the Kit ships the
/// rule primitives, the app declares which categories exist and how they
/// interact. Two requests in the same category share category-level rules.
///
/// ```swift
/// extension SurfaceCategory {
///     static let update: SurfaceCategory = "update"
///     static let promotion: SurfaceCategory = "promotion"
///     static let review: SurfaceCategory = "review"
/// }
/// ```
public struct SurfaceCategory: RawRepresentable, Hashable, Sendable,
    ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    public var description: String { rawValue }
}

/// How strongly a surface interrupts the user. Tiers are a fixed, ordered
/// vocabulary — deliberately not arbitrary numeric priorities, because raw
/// numbers spread across Kits lose their relative meaning.
public enum SurfaceTier: Int, Comparable, Hashable, Sendable {
    /// Non-interruptive rendering (a banner, a badge). Never consumes the
    /// session interruption budget.
    case passive = 0

    /// A modal-style interruption the user must acknowledge or dismiss
    /// (paywall, announcement, review prompt). Consumes the session budget.
    case interruptive = 1

    /// The app cannot meaningfully continue without it (forced update).
    /// Exempt from the session budget and succession rules; still subject to
    /// any cooldown the host explicitly configures and to suppression rules
    /// that opt in via `appliesToBlocking`.
    case blocking = 2

    public static func < (lhs: SurfaceTier, rhs: SurfaceTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One candidate "the app wants to show this" produced by a business feature.
///
/// A request carries only arbitration facts. What the surface looks like —
/// full-screen page, sheet, banner — is entirely the host renderer's business;
/// the Kit never sees it.
///
/// ⚠️ Only **app-initiated** surfaces become requests. A presentation the user
/// explicitly asked for (tapped a button, followed a deep link) must never be
/// arbitrated — denying it would be a bug. See `SurfaceCoordinator` docs.
public struct SurfaceRequest: Identifiable, Hashable, Sendable {
    /// Stable identity of the surface, e.g. `"mono.launch-paywall"`.
    /// Renaming it resets any per-surface cooldown history keyed off it.
    public let id: String

    /// Semantic class used by category-level rules.
    public let category: SurfaceCategory

    /// Interruption strength; decides ordering across candidates and which
    /// rules apply.
    public let tier: SurfaceTier

    /// Key under which per-surface cooldowns are tracked. Defaults to `id`.
    /// Give two requests the same key when they must share one cooldown
    /// (e.g. a campaign shown from two placements).
    public let cooldownKey: String

    public init(
        id: String,
        category: SurfaceCategory,
        tier: SurfaceTier,
        cooldownKey: String? = nil
    ) {
        self.id = id
        self.category = category
        self.tier = tier
        self.cooldownKey = cooldownKey ?? id
    }
}

/// What actually happened after the host renderer took a selected request.
public enum SurfaceOutcome: Sendable, Equatable {
    /// The surface was actually shown to the user. Stamps cooldown history
    /// and consumes the session interruption budget.
    case presented

    /// The host decided not to render after all (e.g. the scene disappeared).
    /// Leaves all state untouched so the surface stays eligible.
    case skipped

    /// Rendering failed. Leaves all state untouched.
    case failed
}
