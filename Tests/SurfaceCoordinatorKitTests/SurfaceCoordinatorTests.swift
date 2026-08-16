import Foundation
import Testing

@testable import SurfaceCoordinatorKit

extension SurfaceCategory {
    fileprivate static let update: SurfaceCategory = "update"
    fileprivate static let promotion: SurfaceCategory = "promotion"
    fileprivate static let review: SurfaceCategory = "review"
    fileprivate static let announcement: SurfaceCategory = "announcement"
}

@MainActor
private final class Clock {
    var current = Date(timeIntervalSince1970: 1_000_000)
    func advance(_ interval: TimeInterval) { current += interval }
}

@MainActor
private func makeCoordinator(
    policies: SurfacePolicySet, clock: Clock
) -> (SurfaceCoordinator, InMemorySurfaceStateStore) {
    let store = InMemorySurfaceStateStore()
    let coordinator = SurfaceCoordinator(
        policies: policies, store: store, now: { clock.current })
    return (coordinator, store)
}

private let forcedUpdate = SurfaceRequest(
    id: "app.forced-update", category: .update, tier: .blocking)
private let launchPaywall = SurfaceRequest(
    id: "app.launch-paywall", category: .promotion, tier: .interruptive)
private let reviewPrompt = SurfaceRequest(
    id: "app.review-prompt", category: .review, tier: .interruptive)
private let promoBanner = SurfaceRequest(
    id: "app.promo-banner", category: .promotion, tier: .passive)

@MainActor
struct TierOrderingTests {
    @Test func blockingOutranksInterruptiveRegardlessOfListingOrder() {
        let (coordinator, _) = makeCoordinator(policies: .init(), clock: Clock())
        let result = coordinator.arbitrate([launchPaywall, forcedUpdate])
        #expect(result.winner == forcedUpdate)
        #expect(result.verdicts.first?.request == forcedUpdate)
        #expect(
            result.verdicts.last?.resolution
                == .rejected(.lostToHigherPriority(winnerID: forcedUpdate.id)))
    }

    @Test func withinTierListingOrderIsPrecedence() {
        let (coordinator, _) = makeCoordinator(policies: .init(), clock: Clock())
        let result = coordinator.arbitrate([reviewPrompt, launchPaywall])
        #expect(result.winner == reviewPrompt)
    }

    @Test func emptyCandidatesYieldNoWinner() {
        let (coordinator, _) = makeCoordinator(policies: .init(), clock: Clock())
        #expect(coordinator.arbitrate([]).winner == nil)
    }
}

@MainActor
struct SessionBudgetTests {
    @Test func secondInterruptiveInSessionIsRejected() {
        let clock = Clock()
        let (coordinator, _) = makeCoordinator(policies: .init(), clock: clock)
        coordinator.beginSession()

        #expect(coordinator.arbitrate([launchPaywall]).winner == launchPaywall)
        coordinator.recordOutcome(.presented, for: launchPaywall)

        let second = coordinator.arbitrate([reviewPrompt])
        #expect(second.winner == nil)
        #expect(second.verdicts.first?.resolution == .rejected(.sessionBudgetExhausted))
    }

    @Test func passiveAndBlockingAreExemptFromBudget() {
        let clock = Clock()
        let (coordinator, _) = makeCoordinator(policies: .init(), clock: clock)
        coordinator.beginSession()
        coordinator.recordOutcome(.presented, for: launchPaywall)

        #expect(coordinator.arbitrate([promoBanner]).winner == promoBanner)
        #expect(coordinator.arbitrate([forcedUpdate]).winner == forcedUpdate)
    }

    @Test func beginSessionResetsBudget() {
        let clock = Clock()
        let (coordinator, _) = makeCoordinator(policies: .init(), clock: clock)
        coordinator.beginSession()
        coordinator.recordOutcome(.presented, for: launchPaywall)
        #expect(coordinator.arbitrate([reviewPrompt]).winner == nil)

        coordinator.beginSession()
        #expect(coordinator.arbitrate([reviewPrompt]).winner == reviewPrompt)
    }

    @Test func configurableBudgetAllowsMultipleInterruptions() {
        let clock = Clock()
        let (coordinator, _) = makeCoordinator(
            policies: .init(sessionInterruptionBudget: 2), clock: clock)
        coordinator.beginSession()
        coordinator.recordOutcome(.presented, for: launchPaywall)
        #expect(coordinator.arbitrate([reviewPrompt]).winner == reviewPrompt)
        coordinator.recordOutcome(.presented, for: reviewPrompt)
        #expect(coordinator.arbitrate([launchPaywall]).winner == nil)
    }
}

@MainActor
struct CooldownTests {
    @Test func surfaceCooldownBlocksUntilIntervalElapses() {
        let clock = Clock()
        let (coordinator, _) = makeCoordinator(
            policies: .init(
                surfaceCooldowns: [launchPaywall.cooldownKey: 24 * 3600],
                sessionInterruptionBudget: 10),
            clock: clock)
        coordinator.recordOutcome(.presented, for: launchPaywall)

        clock.advance(23 * 3600)
        let blocked = coordinator.arbitrate([launchPaywall])
        #expect(blocked.winner == nil)
        guard case .rejected(.surfaceCooldownActive(let remaining)) =
            blocked.verdicts[0].resolution
        else {
            Issue.record("expected surfaceCooldownActive")
            return
        }
        #expect(abs(remaining - 3600) < 1)

        clock.advance(3600)  // exact boundary: elapsed == interval is allowed
        #expect(coordinator.arbitrate([launchPaywall]).winner == launchPaywall)
    }

    @Test func categoryCooldownSpansDifferentSurfaces() {
        let clock = Clock()
        let otherPromotion = SurfaceRequest(
            id: "app.seasonal-offer", category: .promotion, tier: .interruptive)
        let (coordinator, _) = makeCoordinator(
            policies: .init(
                categoryCooldowns: [.promotion: 48 * 3600],
                sessionInterruptionBudget: 10),
            clock: clock)
        coordinator.recordOutcome(.presented, for: launchPaywall)

        clock.advance(3600)
        let blocked = coordinator.arbitrate([otherPromotion])
        #expect(blocked.winner == nil)
        guard case .rejected(.categoryCooldownActive) = blocked.verdicts[0].resolution
        else {
            Issue.record("expected categoryCooldownActive")
            return
        }

        clock.advance(48 * 3600)
        #expect(coordinator.arbitrate([otherPromotion]).winner == otherPromotion)
    }

    @Test func sharedCooldownKeySharesHistory() {
        let clock = Clock()
        let placementA = SurfaceRequest(
            id: "app.offer.launch", category: .promotion, tier: .interruptive,
            cooldownKey: "app.offer")
        let placementB = SurfaceRequest(
            id: "app.offer.settings", category: .promotion, tier: .passive,
            cooldownKey: "app.offer")
        let (coordinator, _) = makeCoordinator(
            policies: .init(surfaceCooldowns: ["app.offer": 3600]), clock: clock)
        coordinator.recordOutcome(.presented, for: placementA)

        let blocked = coordinator.arbitrate([placementB])
        guard case .rejected(.surfaceCooldownActive) = blocked.verdicts[0].resolution
        else {
            Issue.record("expected shared cooldown to block placementB")
            return
        }
    }
}

@MainActor
struct SuccessionTests {
    @Test func reviewBlockedRightAfterPromotion() {
        let clock = Clock()
        let (coordinator, _) = makeCoordinator(
            policies: .init(
                sessionInterruptionBudget: 10,
                successionRules: [
                    .init(previous: .promotion, next: .review, window: 6 * 3600)
                ]),
            clock: clock)
        coordinator.recordOutcome(.presented, for: launchPaywall)

        clock.advance(600)
        let blocked = coordinator.arbitrate([reviewPrompt])
        #expect(blocked.winner == nil)
        guard case .rejected(.successionBlocked(let previous, _)) =
            blocked.verdicts[0].resolution
        else {
            Issue.record("expected successionBlocked")
            return
        }
        #expect(previous == .promotion)

        clock.advance(6 * 3600)
        #expect(coordinator.arbitrate([reviewPrompt]).winner == reviewPrompt)
    }

    @Test func successionRuleIsDirectional() {
        let clock = Clock()
        let (coordinator, _) = makeCoordinator(
            policies: .init(
                sessionInterruptionBudget: 10,
                successionRules: [
                    .init(previous: .promotion, next: .review, window: 6 * 3600)
                ]),
            clock: clock)
        coordinator.recordOutcome(.presented, for: reviewPrompt)
        clock.advance(600)
        #expect(coordinator.arbitrate([launchPaywall]).winner == launchPaywall)
    }

    @Test func blockingTierIgnoresSuccessionRules() {
        let clock = Clock()
        let blockingReview = SurfaceRequest(
            id: "app.blocking-review", category: .review, tier: .blocking)
        let (coordinator, _) = makeCoordinator(
            policies: .init(
                successionRules: [
                    .init(previous: .promotion, next: .review, window: 6 * 3600)
                ]),
            clock: clock)
        coordinator.recordOutcome(.presented, for: launchPaywall)
        clock.advance(600)
        #expect(coordinator.arbitrate([blockingReview]).winner == blockingReview)
    }
}

@MainActor
struct SignalSuppressionTests {
    private let policies = SurfacePolicySet(
        sessionInterruptionBudget: 10,
        suppressionRules: [
            .init(signalKey: "critical-flow"),
            .init(signalKey: "purchase-failed", categories: [.review]),
            .init(signalKey: "system-dialog", appliesToBlocking: true),
        ])

    @Test func activeSignalSuppressesEverythingItCovers() {
        let (coordinator, _) = makeCoordinator(policies: policies, clock: Clock())
        coordinator.registerSignal("critical-flow")

        let result = coordinator.arbitrate([launchPaywall, promoBanner])
        #expect(result.winner == nil)
        for verdict in result.verdicts {
            #expect(
                verdict.resolution
                    == .rejected(.suppressedBySignal(key: "critical-flow")))
        }

        coordinator.clearSignal("critical-flow")
        #expect(coordinator.arbitrate([launchPaywall]).winner == launchPaywall)
    }

    @Test func categoryScopedSignalOnlyHitsThatCategory() {
        let (coordinator, _) = makeCoordinator(policies: policies, clock: Clock())
        coordinator.registerSignal("purchase-failed")

        #expect(coordinator.arbitrate([launchPaywall]).winner == launchPaywall)
        let review = coordinator.arbitrate([reviewPrompt])
        #expect(
            review.verdicts[0].resolution
                == .rejected(.suppressedBySignal(key: "purchase-failed")))
    }

    @Test func blockingIsExemptUnlessRuleOptsIn() {
        let (coordinator, _) = makeCoordinator(policies: policies, clock: Clock())
        coordinator.registerSignal("critical-flow")
        #expect(coordinator.arbitrate([forcedUpdate]).winner == forcedUpdate)

        coordinator.registerSignal("system-dialog")
        let result = coordinator.arbitrate([forcedUpdate])
        #expect(
            result.verdicts[0].resolution
                == .rejected(.suppressedBySignal(key: "system-dialog")))
    }

    @Test func expiredSignalNoLongerSuppresses() {
        let clock = Clock()
        let (coordinator, _) = makeCoordinator(policies: policies, clock: clock)
        coordinator.registerSignal("critical-flow", expiresAfter: 300)

        #expect(coordinator.arbitrate([launchPaywall]).winner == nil)
        clock.advance(301)
        #expect(coordinator.arbitrate([launchPaywall]).winner == launchPaywall)
    }
}

@MainActor
struct OutcomeRecordingTests {
    @Test func arbitrationAloneStampsNothing() {
        let clock = Clock()
        let (coordinator, store) = makeCoordinator(
            policies: .init(surfaceCooldowns: [launchPaywall.cooldownKey: 3600]),
            clock: clock)
        _ = coordinator.arbitrate([launchPaywall])
        #expect(store.lastPresentation(cooldownKey: launchPaywall.cooldownKey) == nil)
        #expect(coordinator.arbitrate([launchPaywall]).winner == launchPaywall)
    }

    @Test func skippedAndFailedLeaveStateUntouched() {
        let clock = Clock()
        let (coordinator, store) = makeCoordinator(
            policies: .init(surfaceCooldowns: [launchPaywall.cooldownKey: 3600]),
            clock: clock)
        coordinator.recordOutcome(.skipped, for: launchPaywall)
        coordinator.recordOutcome(.failed, for: launchPaywall)
        #expect(store.lastPresentation(cooldownKey: launchPaywall.cooldownKey) == nil)
        #expect(coordinator.arbitrate([launchPaywall]).winner == launchPaywall)
    }

    @Test func presentedStampsBothSurfaceAndCategory() {
        let clock = Clock()
        let (coordinator, store) = makeCoordinator(policies: .init(), clock: clock)
        coordinator.recordOutcome(.presented, for: launchPaywall)
        #expect(
            store.lastPresentation(cooldownKey: launchPaywall.cooldownKey)
                == clock.current)
        #expect(store.lastPresentation(category: .promotion) == clock.current)
    }
}

@MainActor
struct UserDefaultsStoreTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "SurfaceCoordinatorKitTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func persistsAndResets() {
        let store = UserDefaultsSurfaceStateStore(userDefaults: makeDefaults())
        let date = Date(timeIntervalSince1970: 2_000_000)
        store.recordPresentation(cooldownKey: "key", category: .promotion, at: date)
        #expect(store.lastPresentation(cooldownKey: "key") == date)
        #expect(store.lastPresentation(category: .promotion) == date)
        store.reset()
        #expect(store.lastPresentation(cooldownKey: "key") == nil)
        #expect(store.lastPresentation(category: .promotion) == nil)
    }

    @Test func seedingNeverRewindsExistingHistory() {
        let store = UserDefaultsSurfaceStateStore(userDefaults: makeDefaults())
        let newer = Date(timeIntervalSince1970: 2_000_000)
        let older = Date(timeIntervalSince1970: 1_000_000)
        store.recordPresentation(cooldownKey: "key", category: .promotion, at: newer)
        store.seedPresentation(cooldownKey: "key", category: .promotion, at: older)
        #expect(store.lastPresentation(cooldownKey: "key") == newer)

        store.seedPresentation(cooldownKey: "fresh", category: .announcement, at: older)
        #expect(store.lastPresentation(cooldownKey: "fresh") == older)
    }
}
