import Foundation

/// "Category B must not appear within `window` after category A was presented."
///
/// Typical use: a review prompt must not immediately follow a paywall.
public struct SurfaceSuccessionRule: Sendable, Equatable {
    /// Category whose recent presentation blocks `next`.
    public let previous: SurfaceCategory

    /// Category being blocked.
    public let next: SurfaceCategory

    /// How long after a `previous` presentation the block lasts.
    public let window: TimeInterval

    public init(previous: SurfaceCategory, next: SurfaceCategory, window: TimeInterval) {
        self.previous = previous
        self.next = next
        self.window = window
    }
}

/// "While signal `signalKey` is active, defer surfaces."
///
/// Signals are opaque to the Kit: the host registers them
/// (`SurfaceCoordinator.registerSignal`) when something is going on that
/// should defer app-initiated surfaces — a user-initiated sheet is visible,
/// a system permission prompt is up, the user is inside a critical flow,
/// a purchase just failed. The Kit never needs to know what a key means.
public struct SurfaceSuppressionRule: Sendable, Equatable {
    /// The signal that activates this suppression.
    public let signalKey: String

    /// Categories this suppression applies to. `nil` means all categories.
    public let categories: Set<SurfaceCategory>?

    /// Whether `.blocking`-tier requests are also suppressed. Defaults to
    /// `false`: a forced update normally outranks everything, so only signals
    /// that make *any* presentation impossible (e.g. a system dialog is
    /// covering the screen) should opt in.
    public let appliesToBlocking: Bool

    public init(
        signalKey: String,
        categories: Set<SurfaceCategory>? = nil,
        appliesToBlocking: Bool = false
    ) {
        self.signalKey = signalKey
        self.categories = categories
        self.appliesToBlocking = appliesToBlocking
    }

    func applies(to request: SurfaceRequest) -> Bool {
        if request.tier == .blocking && !appliesToBlocking { return false }
        guard let categories else { return true }
        return categories.contains(request.category)
    }
}

/// The declarative rule set one app hands to its `SurfaceCoordinator`.
///
/// The Kit owns the rule *primitives* (cooldown, budget, succession,
/// suppression) and their evaluation; the app owns the *parameters* — which
/// categories exist, which intervals apply, which signals veto what. Keep the
/// whole policy in one place in the host app so the arbitration behavior is
/// reviewable at a glance.
public struct SurfacePolicySet: Sendable {
    /// Minimum interval between two presentations sharing a cooldown key.
    /// Keys without an entry have no per-surface cooldown.
    public var surfaceCooldowns: [String: TimeInterval]

    /// Minimum interval between two presentations of the same category
    /// (e.g. any two promotions at least N hours apart).
    public var categoryCooldowns: [SurfaceCategory: TimeInterval]

    /// How many `.interruptive` presentations one foreground session may
    /// contain. `.blocking` and `.passive` requests are exempt.
    public var sessionInterruptionBudget: Int

    /// Ordered succession bans between categories.
    public var successionRules: [SurfaceSuccessionRule]

    /// Signal-driven deferrals.
    public var suppressionRules: [SurfaceSuppressionRule]

    public init(
        surfaceCooldowns: [String: TimeInterval] = [:],
        categoryCooldowns: [SurfaceCategory: TimeInterval] = [:],
        sessionInterruptionBudget: Int = 1,
        successionRules: [SurfaceSuccessionRule] = [],
        suppressionRules: [SurfaceSuppressionRule] = []
    ) {
        self.surfaceCooldowns = surfaceCooldowns
        self.categoryCooldowns = categoryCooldowns
        self.sessionInterruptionBudget = sessionInterruptionBudget
        self.successionRules = successionRules
        self.suppressionRules = suppressionRules
    }
}
