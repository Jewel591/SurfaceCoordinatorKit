import Foundation

/// Semantic class of an app-initiated surface, used by cross-surface rules
/// (category cooldowns, forbidden successions).
///
/// Categories are host-defined vocabulary, not a fixed enum: the Kit ships the
/// rule primitives, the app declares which categories exist and how they
/// interact. Two producers in the same category share category-level rules.
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
    /// Non-interruptive rendering (a banner, a badge). Persistent passive UI
    /// renders from its own domain state and never registers a producer:
    /// it must not compete for the single modal permit.
    case passive = 0

    /// A modal the user can dismiss (paywall, announcement, update prompt,
    /// review prompt). Consumes the session budget.
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

/// House order of producers inside one tier. Earlier cases win.
///
/// This is a fixed semantic vocabulary owned by the Kit, not a priority
/// number: a producer states *what kind of interruption it is*, and the Kit
/// decides the order once for every app. Producers sharing a purpose are
/// ordered by their stable `SurfaceProducerID`, never by registration or
/// submission timing.
public enum SurfacePurpose: Int, Comparable, CaseIterable, Hashable, Sendable {
    /// Something happened to the user's data or account that they must
    /// acknowledge (data recovery, account notices).
    case attention = 0

    /// A newer app version is available.
    case update = 1

    /// What's New, feature introductions, one-time guides.
    case announcement = 2

    /// Launch paywalls and promotion launch modals.
    case monetization = 3

    /// Maintenance prompts that ask the user to confirm a cleanup.
    case housekeeping = 4

    /// Review requests and other engagement asks.
    case engagement = 5

    public static func < (lhs: SurfacePurpose, rhs: SurfacePurpose) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// How the adapter renders a producer once it wins the permit.
public enum SurfacePresentationStyle: Hashable, Sendable {
    /// A dismissible sheet.
    case sheet

    /// A full-screen cover. Maps to a sheet where the platform has no cover.
    case fullScreenCover

    /// System UI the app cannot observe (StoreKit review request). The
    /// adapter performs it and records an attempt; it never counts as
    /// presented and never consumes the modal budget.
    case unobservable
}

/// Stable identity of a producer. Renaming one resets its per-surface
/// cooldown history and changes its in-purpose order.
public struct SurfaceProducerID: RawRepresentable, Hashable, Comparable, Sendable,
    ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    public var description: String { rawValue }

    public static func < (lhs: SurfaceProducerID, rhs: SurfaceProducerID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

extension SurfaceProducerID {
    /// Standard IDs for surfaces whose domain Kit will own the producer.
    /// Hosts that still assemble these surfaces themselves use the same IDs,
    /// so cooldown history carries over when the Kit takes the producer.
    public static let appUpdate: SurfaceProducerID = "surface.app-update"
    public static let whatsNew: SurfaceProducerID = "surface.whats-new"
    public static let launchPromotion: SurfaceProducerID = "surface.launch-promotion"
    public static let review: SurfaceProducerID = "surface.review"
}

/// One app-initiated surface that can compete for the permit.
///
/// A producer carries only arbitration facts and a presentation style. What
/// it looks like is the host's content view; the Kit never sees it.
///
/// ⚠️ Only **app-initiated** surfaces become producers. A presentation the
/// user explicitly asked for (tapped a button, followed a deep link) stays in
/// the host's own presentation layer and only reports occupancy.
public struct SurfaceProducer: Hashable, Sendable, CustomStringConvertible {
    public let id: SurfaceProducerID

    /// Semantic class used by category-level rules.
    public let category: SurfaceCategory

    /// Interruption strength. Only `.interruptive` and `.blocking` producers
    /// exist; persistent passive UI does not compete for the permit.
    public let tier: SurfaceTier

    /// House order inside the tier.
    public let purpose: SurfacePurpose

    public let style: SurfacePresentationStyle

    /// Key under which per-surface cooldowns are tracked. Defaults to the id.
    public let cooldownKey: String

    public init(
        id: SurfaceProducerID,
        category: SurfaceCategory,
        tier: SurfaceTier = .interruptive,
        purpose: SurfacePurpose,
        style: SurfacePresentationStyle = .sheet,
        cooldownKey: String? = nil
    ) {
        precondition(
            tier != .passive,
            "Passive UI renders from its own state and never registers a surface producer.")
        self.id = id
        self.category = category
        self.tier = tier
        self.purpose = purpose
        self.style = style
        self.cooldownKey = cooldownKey ?? id.rawValue
    }

    public var description: String { id.rawValue }

    /// Whether `self` is evaluated before `other` in one round.
    func precedes(_ other: SurfaceProducer) -> Bool {
        if tier != other.tier { return tier > other.tier }
        if purpose != other.purpose { return purpose < other.purpose }
        return id < other.id
    }
}

/// What happened to one presentation attempt.
public enum SurfaceOutcome: Sendable, Equatable {
    /// The adapter confirmed the content reached the target window. Stamps
    /// cooldown history and consumes the session interruption budget.
    case presented

    /// Withdrawn or abandoned before it reached the screen. State untouched.
    case skipped

    /// Did not reach the screen in time. State untouched; retried within a
    /// bounded number of attempts.
    case failed

    /// Unobservable system UI was requested. No cooldown stamp and no budget,
    /// but no other interruptive surface follows in the same session.
    case attempted
}
