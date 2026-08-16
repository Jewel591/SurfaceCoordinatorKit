import Foundation
import OSLog

/// Arbitrates which **app-initiated** surface, if any, is shown next.
///
/// ## Scope norm (the contract this Kit exists to enforce)
///
/// - **App-initiated interruptions go through the coordinator.** Forced and
///   optional update prompts, launch paywalls, promotions, announcements,
///   What's New, review prompts, recovery hints — anything the user did not
///   ask for. These are the only presentations where "should this show now,
///   and which one" is a real question.
/// - **User-initiated presentations never go through it.** When the user taps
///   a button or follows a deep link, they expect the page immediately;
///   arbitrating (and possibly denying) that is a bug, not a policy. Present
///   directly through the app's own presentation layer.
/// - The same page may have both identities (a paywall opened from settings
///   vs. auto-shown at launch). Reuse the page, split the entry points: only
///   the app-initiated entry is arbitrated.
/// - User-initiated activity should still *inform* arbitration: report it as
///   a context signal (`registerSignal`) so app-initiated surfaces defer
///   while the user is busy.
///
/// ## Division of labor
///
/// The Kit owns *why and when* (rule primitives, evaluation, outcome
/// recording, persistence). The host owns *what it looks like* (rendering:
/// full-screen page, sheet, banner) and *the parameters* (the `SurfacePolicySet`).
/// The Kit performs no presentation and has no UI dependency.
@MainActor
public final class SurfaceCoordinator {
    private let policies: SurfacePolicySet
    private let store: SurfaceStateStoring
    private let now: () -> Date
    private let logger = Logger(
        subsystem: "SurfaceCoordinatorKit", category: "SurfaceCoordinator")

    /// Active context signals and their optional expiry.
    private var signals: [String: Date?] = [:]

    /// `.interruptive` presentations recorded in the current foreground session.
    private var sessionInterruptionCount = 0

    public init(
        policies: SurfacePolicySet,
        store: SurfaceStateStoring? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.policies = policies
        self.store = store ?? UserDefaultsSurfaceStateStore()
        self.now = now
    }

    // MARK: - Session

    /// Marks the start of a foreground session, resetting the session
    /// interruption budget. Call on launch and on return to foreground —
    /// the host decides what counts as a new session (e.g. only after N
    /// minutes in background).
    public func beginSession() {
        sessionInterruptionCount = 0
    }

    // MARK: - Context signals

    /// Registers an opaque context signal, optionally self-expiring.
    ///
    /// The Kit does not know what a key means; suppression rules in the
    /// policy set reference keys. Use signals for: a user-initiated sheet is
    /// visible, a system permission prompt is up, the user entered a critical
    /// flow, a purchase just failed, feedback was just submitted.
    public func registerSignal(_ key: String, expiresAfter: TimeInterval? = nil) {
        // updateValue, not subscript assignment: assigning `nil` through the
        // subscript of a [String: Date?] removes the key instead of storing
        // a nil expiry.
        signals.updateValue(
            expiresAfter.map { now().addingTimeInterval($0) }, forKey: key)
    }

    /// Clears a previously registered signal.
    public func clearSignal(_ key: String) {
        signals.removeValue(forKey: key)
    }

    /// Whether a signal is currently active (registered and not expired).
    public func isSignalActive(_ key: String) -> Bool {
        guard let expiry = signals[key] else { return false }
        guard let expiry else { return true }
        if expiry > now() { return true }
        signals.removeValue(forKey: key)
        return false
    }

    // MARK: - Arbitration

    /// Decides which of the given candidates, if any, should be presented now.
    ///
    /// Candidates are evaluated tier-descending; within a tier, the order the
    /// host listed them in is their precedence (no numeric priorities). The
    /// first candidate passing every rule wins; every candidate receives a
    /// verdict with a reason. The round is also logged.
    ///
    /// Arbitration does **not** stamp any state: the winner only affects
    /// future rounds once the host reports `recordOutcome(.presented, ...)`.
    public func arbitrate(_ candidates: [SurfaceRequest]) -> SurfaceArbitration {
        let ordered = candidates.enumerated().sorted { lhs, rhs in
            if lhs.element.tier != rhs.element.tier {
                return lhs.element.tier > rhs.element.tier
            }
            return lhs.offset < rhs.offset
        }.map(\.element)

        let currentDate = now()
        var winner: SurfaceRequest?
        var verdicts: [SurfaceVerdict] = []

        for request in ordered {
            if let rejection = rejectionReason(for: request, at: currentDate) {
                verdicts.append(.init(request: request, resolution: .rejected(rejection)))
            } else if let winner {
                verdicts.append(.init(
                    request: request,
                    resolution: .rejected(.lostToHigherPriority(winnerID: winner.id))))
            } else {
                winner = request
                verdicts.append(.init(request: request, resolution: .selected))
            }
        }

        let arbitration = SurfaceArbitration(winner: winner, verdicts: verdicts)
        logger.debug("arbitration: \(arbitration.summary, privacy: .public)")
        return arbitration
    }

    /// Reports what the host renderer actually did with a selected request.
    ///
    /// Only `.presented` mutates state (cooldown stamps, session budget);
    /// `.skipped` and `.failed` leave the surface fully eligible for the next
    /// round. Never report `.presented` for a surface that did not actually
    /// reach the screen.
    public func recordOutcome(_ outcome: SurfaceOutcome, for request: SurfaceRequest) {
        guard outcome == .presented else {
            logger.debug(
                "outcome \(String(describing: outcome), privacy: .public) for \(request.id, privacy: .public): state untouched")
            return
        }
        store.recordPresentation(
            cooldownKey: request.cooldownKey, category: request.category, at: now())
        if request.tier == .interruptive {
            sessionInterruptionCount += 1
        }
        logger.debug("presented \(request.id, privacy: .public)")
    }

    // MARK: - Rules

    private func rejectionReason(
        for request: SurfaceRequest, at date: Date
    ) -> SurfaceRejectionReason? {
        for rule in policies.suppressionRules where rule.applies(to: request) {
            if isSignalActive(rule.signalKey) {
                return .suppressedBySignal(key: rule.signalKey)
            }
        }

        if let interval = policies.surfaceCooldowns[request.cooldownKey],
            let last = store.lastPresentation(cooldownKey: request.cooldownKey) {
            let elapsed = date.timeIntervalSince(last)
            if elapsed < interval {
                return .surfaceCooldownActive(remaining: interval - elapsed)
            }
        }

        if let interval = policies.categoryCooldowns[request.category],
            let last = store.lastPresentation(category: request.category) {
            let elapsed = date.timeIntervalSince(last)
            if elapsed < interval {
                return .categoryCooldownActive(remaining: interval - elapsed)
            }
        }

        if request.tier != .blocking {
            for rule in policies.successionRules where rule.next == request.category {
                if let last = store.lastPresentation(category: rule.previous) {
                    let elapsed = date.timeIntervalSince(last)
                    if elapsed < rule.window {
                        return .successionBlocked(
                            previous: rule.previous, remaining: rule.window - elapsed)
                    }
                }
            }
        }

        if request.tier == .interruptive,
            sessionInterruptionCount >= policies.sessionInterruptionBudget {
            return .sessionBudgetExhausted
        }

        return nil
    }
}
