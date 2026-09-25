import Foundation

/// Rule evaluation behind `SurfaceCoordinator`.
///
/// Pure decision logic plus the presentation history it reads: tier and
/// house ordering, cooldowns, succession bans, signal suppression and the
/// session interruption budget. It owns no permit, no candidate list and no
/// UI; the coordinator decides *when* to ask and what to do with the answer.
@MainActor
final class SurfaceArbiter {
    var policies: SurfacePolicySet
    let store: SurfaceStateStoring
    private let now: () -> Date

    /// Active context signals and their optional expiry.
    private var signals: [String: Date?] = [:]

    /// `.interruptive` presentations recorded in the current session.
    private var sessionInterruptionCount = 0

    init(policies: SurfacePolicySet, store: SurfaceStateStoring, now: @escaping () -> Date) {
        self.policies = policies
        self.store = store
        self.now = now
    }

    // MARK: - Session

    func beginSession() {
        sessionInterruptionCount = 0
    }

    // MARK: - Context signals

    func registerSignal(_ key: String, expiresAfter: TimeInterval? = nil) {
        // updateValue, not subscript assignment: assigning `nil` through the
        // subscript of a [String: Date?] removes the key instead of storing
        // a nil expiry.
        signals.updateValue(
            expiresAfter.map { now().addingTimeInterval($0) }, forKey: key)
    }

    func clearSignal(_ key: String) {
        signals.removeValue(forKey: key)
    }

    func clearAllSignals() {
        signals.removeAll()
    }

    func isSignalActive(_ key: String) -> Bool {
        guard let expiry = signals[key] else { return false }
        guard let expiry else { return true }
        if expiry > now() { return true }
        signals.removeValue(forKey: key)
        return false
    }

    // MARK: - Arbitration

    /// Evaluates candidates in house order (tier, then purpose, then id) and
    /// selects the first one passing every rule. Stamps nothing.
    func arbitrate(_ candidates: [SurfaceProducer]) -> SurfaceArbitration {
        let ordered = candidates.sorted { $0.precedes($1) }
        let currentDate = now()
        var winner: SurfaceProducer?
        var verdicts: [SurfaceVerdict] = []

        for producer in ordered {
            if let rejection = rejectionReason(for: producer, at: currentDate) {
                verdicts.append(.init(producer: producer, resolution: .rejected(rejection)))
            } else if let winner {
                verdicts.append(.init(
                    producer: producer,
                    resolution: .rejected(.lostToHigherPriority(winnerID: winner.id))))
            } else {
                winner = producer
                verdicts.append(.init(producer: producer, resolution: .selected))
            }
        }

        return SurfaceArbitration(winner: winner, verdicts: verdicts)
    }

    /// Stamps cooldown history and, for interruptive producers, the session
    /// budget. Only a confirmed presentation reaches this.
    func recordPresented(_ producer: SurfaceProducer) {
        store.recordPresentation(
            cooldownKey: producer.cooldownKey, category: producer.category, at: now())
        if producer.tier == .interruptive {
            sessionInterruptionCount += 1
        }
    }

    // MARK: - Rules

    private func rejectionReason(
        for producer: SurfaceProducer, at date: Date
    ) -> SurfaceRejectionReason? {
        for rule in policies.suppressionRules where rule.applies(to: producer) {
            if isSignalActive(rule.signalKey) {
                return .suppressedBySignal(key: rule.signalKey)
            }
        }

        if let interval = policies.surfaceCooldowns[producer.cooldownKey],
            let last = store.lastPresentation(cooldownKey: producer.cooldownKey) {
            let elapsed = date.timeIntervalSince(last)
            if elapsed < interval {
                return .surfaceCooldownActive(remaining: interval - elapsed)
            }
        }

        if let interval = policies.categoryCooldowns[producer.category],
            let last = store.lastPresentation(category: producer.category) {
            let elapsed = date.timeIntervalSince(last)
            if elapsed < interval {
                return .categoryCooldownActive(remaining: interval - elapsed)
            }
        }

        if producer.tier != .blocking {
            for rule in policies.successionRules where rule.next == producer.category {
                if let last = store.lastPresentation(category: rule.previous) {
                    let elapsed = date.timeIntervalSince(last)
                    if elapsed < rule.window {
                        return .successionBlocked(
                            previous: rule.previous, remaining: rule.window - elapsed)
                    }
                }
            }
        }

        if producer.tier == .interruptive,
            sessionInterruptionCount >= policies.sessionInterruptionBudget {
            return .sessionBudgetExhausted
        }

        return nil
    }
}
