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
private func makeArbiter(
    policies: SurfacePolicySet, clock: Clock
) -> (SurfaceArbiter, InMemorySurfaceStateStore) {
    let store = InMemorySurfaceStateStore()
    let arbiter = SurfaceArbiter(
        policies: policies, store: store, now: { clock.current })
    return (arbiter, store)
}

private let forcedUpdate = SurfaceProducer(
    id: "app.forced-update", category: .update, tier: .blocking, purpose: .update)
private let launchPaywall = SurfaceProducer(
    id: "app.launch-paywall", category: .promotion, purpose: .monetization)
private let reviewPrompt = SurfaceProducer(
    id: "app.review-prompt", category: .review, purpose: .engagement)

@MainActor
struct TierOrderingTests {
    @Test func blockingOutranksInterruptiveRegardlessOfListingOrder() {
        let (arbiter, _) = makeArbiter(policies: .init(), clock: Clock())
        let result = arbiter.arbitrate([launchPaywall, forcedUpdate])
        #expect(result.winner == forcedUpdate)
        #expect(result.verdicts.first?.producer == forcedUpdate)
        #expect(
            result.verdicts.last?.resolution
                == .rejected(.lostToHigherPriority(winnerID: forcedUpdate.id)))
    }

    @Test func withinTierPurposeDecidesRegardlessOfListingOrder() {
        let (arbiter, _) = makeArbiter(policies: .init(), clock: Clock())
        #expect(arbiter.arbitrate([reviewPrompt, launchPaywall]).winner == launchPaywall)
        #expect(arbiter.arbitrate([launchPaywall, reviewPrompt]).winner == launchPaywall)
    }

    @Test func samePurposeOrdersByProducerID() {
        let (arbiter, _) = makeArbiter(policies: .init(), clock: Clock())
        let alpha = SurfaceProducer(id: "a.guide", category: .announcement, purpose: .announcement)
        let beta = SurfaceProducer(id: "b.guide", category: .announcement, purpose: .announcement)
        #expect(arbiter.arbitrate([beta, alpha]).winner == alpha)
        #expect(arbiter.arbitrate([alpha, beta]).winner == alpha)
    }

    @Test func emptyCandidatesYieldNoWinner() {
        let (arbiter, _) = makeArbiter(policies: .init(), clock: Clock())
        #expect(arbiter.arbitrate([]).winner == nil)
    }
}

@MainActor
struct SessionBudgetTests {
    @Test func secondInterruptiveInSessionIsRejected() {
        let clock = Clock()
        let (arbiter, _) = makeArbiter(policies: .init(), clock: clock)
        arbiter.beginSession()

        #expect(arbiter.arbitrate([launchPaywall]).winner == launchPaywall)
        arbiter.recordPresented(launchPaywall)

        let second = arbiter.arbitrate([reviewPrompt])
        #expect(second.winner == nil)
        #expect(second.verdicts.first?.resolution == .rejected(.sessionBudgetExhausted))
    }

    @Test func blockingIsExemptFromBudget() {
        let clock = Clock()
        let (arbiter, _) = makeArbiter(policies: .init(), clock: clock)
        arbiter.beginSession()
        arbiter.recordPresented(launchPaywall)

        #expect(arbiter.arbitrate([forcedUpdate]).winner == forcedUpdate)
    }

    @Test func beginSessionResetsBudget() {
        let clock = Clock()
        let (arbiter, _) = makeArbiter(policies: .init(), clock: clock)
        arbiter.beginSession()
        arbiter.recordPresented(launchPaywall)
        #expect(arbiter.arbitrate([reviewPrompt]).winner == nil)

        arbiter.beginSession()
        #expect(arbiter.arbitrate([reviewPrompt]).winner == reviewPrompt)
    }

    @Test func clearingSignalsDoesNotResetSessionBudget() {
        let clock = Clock()
        let (arbiter, _) = makeArbiter(policies: .init(), clock: clock)
        arbiter.beginSession()
        arbiter.registerSignal("critical-flow")
        arbiter.recordPresented(launchPaywall)

        arbiter.clearAllSignals()

        #expect(!arbiter.isSignalActive("critical-flow"))
        let result = arbiter.arbitrate([reviewPrompt])
        #expect(result.winner == nil)
        #expect(result.verdicts.first?.resolution == .rejected(.sessionBudgetExhausted))
    }

    @Test func configurableBudgetAllowsMultipleInterruptions() {
        let clock = Clock()
        let (arbiter, _) = makeArbiter(
            policies: .init(sessionInterruptionBudget: 2), clock: clock)
        arbiter.beginSession()
        arbiter.recordPresented(launchPaywall)
        #expect(arbiter.arbitrate([reviewPrompt]).winner == reviewPrompt)
        arbiter.recordPresented(reviewPrompt)
        #expect(arbiter.arbitrate([launchPaywall]).winner == nil)
    }
}

@MainActor
struct CooldownTests {
    @Test func surfaceCooldownBlocksUntilIntervalElapses() {
        let clock = Clock()
        let (arbiter, _) = makeArbiter(
            policies: .init(
                surfaceCooldowns: [launchPaywall.cooldownKey: 24 * 3600],
                sessionInterruptionBudget: 10),
            clock: clock)
        arbiter.recordPresented(launchPaywall)

        clock.advance(23 * 3600)
        let blocked = arbiter.arbitrate([launchPaywall])
        #expect(blocked.winner == nil)
        guard case .rejected(.surfaceCooldownActive(let remaining)) =
            blocked.verdicts[0].resolution
        else {
            Issue.record("expected surfaceCooldownActive")
            return
        }
        #expect(abs(remaining - 3600) < 1)

        clock.advance(3600)  // exact boundary: elapsed == interval is allowed
        #expect(arbiter.arbitrate([launchPaywall]).winner == launchPaywall)
    }

    @Test func categoryCooldownSpansDifferentSurfaces() {
        let clock = Clock()
        let otherPromotion = SurfaceProducer(
            id: "app.seasonal-offer", category: .promotion, purpose: .monetization)
        let (arbiter, _) = makeArbiter(
            policies: .init(
                categoryCooldowns: [.promotion: 48 * 3600],
                sessionInterruptionBudget: 10),
            clock: clock)
        arbiter.recordPresented(launchPaywall)

        clock.advance(3600)
        let blocked = arbiter.arbitrate([otherPromotion])
        #expect(blocked.winner == nil)
        guard case .rejected(.categoryCooldownActive) = blocked.verdicts[0].resolution
        else {
            Issue.record("expected categoryCooldownActive")
            return
        }

        // exact boundary: elapsed == interval is allowed
        clock.advance(48 * 3600 - 3600)
        #expect(arbiter.arbitrate([otherPromotion]).winner == otherPromotion)
    }

    @Test func sharedCooldownKeySharesHistory() {
        let clock = Clock()
        let placementA = SurfaceProducer(
            id: "app.offer.launch", category: .promotion, purpose: .monetization,
            cooldownKey: "app.offer")
        let placementB = SurfaceProducer(
            id: "app.offer.resume", category: .promotion, purpose: .monetization,
            cooldownKey: "app.offer")
        let (arbiter, _) = makeArbiter(
            policies: .init(surfaceCooldowns: ["app.offer": 3600]), clock: clock)
        arbiter.recordPresented(placementA)

        let blocked = arbiter.arbitrate([placementB])
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
        let (arbiter, _) = makeArbiter(
            policies: .init(
                sessionInterruptionBudget: 10,
                successionRules: [
                    .init(previous: .promotion, next: .review, window: 6 * 3600)
                ]),
            clock: clock)
        arbiter.recordPresented(launchPaywall)

        clock.advance(600)
        let blocked = arbiter.arbitrate([reviewPrompt])
        #expect(blocked.winner == nil)
        guard case .rejected(.successionBlocked(let previous, _)) =
            blocked.verdicts[0].resolution
        else {
            Issue.record("expected successionBlocked")
            return
        }
        #expect(previous == .promotion)

        // exact boundary: elapsed == window is allowed
        clock.advance(6 * 3600 - 600)
        #expect(arbiter.arbitrate([reviewPrompt]).winner == reviewPrompt)
    }

    @Test func successionRuleIsDirectional() {
        let clock = Clock()
        let (arbiter, _) = makeArbiter(
            policies: .init(
                sessionInterruptionBudget: 10,
                successionRules: [
                    .init(previous: .promotion, next: .review, window: 6 * 3600)
                ]),
            clock: clock)
        arbiter.recordPresented(reviewPrompt)
        clock.advance(600)
        #expect(arbiter.arbitrate([launchPaywall]).winner == launchPaywall)
    }

    @Test func blockingTierIgnoresSuccessionRules() {
        let clock = Clock()
        let blockingReview = SurfaceProducer(
            id: "app.blocking-review", category: .review, tier: .blocking, purpose: .engagement)
        let (arbiter, _) = makeArbiter(
            policies: .init(
                successionRules: [
                    .init(previous: .promotion, next: .review, window: 6 * 3600)
                ]),
            clock: clock)
        arbiter.recordPresented(launchPaywall)
        clock.advance(600)
        #expect(arbiter.arbitrate([blockingReview]).winner == blockingReview)
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
        let (arbiter, _) = makeArbiter(policies: policies, clock: Clock())
        arbiter.registerSignal("critical-flow")

        let result = arbiter.arbitrate([launchPaywall, reviewPrompt])
        #expect(result.winner == nil)
        for verdict in result.verdicts {
            #expect(
                verdict.resolution
                    == .rejected(.suppressedBySignal(key: "critical-flow")))
        }

        arbiter.clearSignal("critical-flow")
        #expect(arbiter.arbitrate([launchPaywall]).winner == launchPaywall)
    }

    @Test func categoryScopedSignalOnlyHitsThatCategory() {
        let (arbiter, _) = makeArbiter(policies: policies, clock: Clock())
        arbiter.registerSignal("purchase-failed")

        #expect(arbiter.arbitrate([launchPaywall]).winner == launchPaywall)
        let review = arbiter.arbitrate([reviewPrompt])
        #expect(
            review.verdicts[0].resolution
                == .rejected(.suppressedBySignal(key: "purchase-failed")))
    }

    @Test func blockingIsExemptUnlessRuleOptsIn() {
        let (arbiter, _) = makeArbiter(policies: policies, clock: Clock())
        arbiter.registerSignal("critical-flow")
        #expect(arbiter.arbitrate([forcedUpdate]).winner == forcedUpdate)

        arbiter.registerSignal("system-dialog")
        let result = arbiter.arbitrate([forcedUpdate])
        #expect(
            result.verdicts[0].resolution
                == .rejected(.suppressedBySignal(key: "system-dialog")))
    }

    @Test func expiredSignalNoLongerSuppresses() {
        let clock = Clock()
        let (arbiter, _) = makeArbiter(policies: policies, clock: clock)
        arbiter.registerSignal("critical-flow", expiresAfter: 300)

        #expect(arbiter.arbitrate([launchPaywall]).winner == nil)
        clock.advance(299)
        #expect(arbiter.arbitrate([launchPaywall]).winner == nil)
        // exact boundary: a signal is expired the moment now == expiry
        clock.advance(1)
        #expect(arbiter.arbitrate([launchPaywall]).winner == launchPaywall)
    }

    @Test func clearAllSignalsDropsEveryKeyIncludingUnexpired() {
        let clock = Clock()
        let (arbiter, _) = makeArbiter(policies: policies, clock: clock)
        arbiter.registerSignal("critical-flow")
        arbiter.registerSignal("purchase-failed", expiresAfter: 300)

        arbiter.clearAllSignals()

        #expect(!arbiter.isSignalActive("critical-flow"))
        #expect(!arbiter.isSignalActive("purchase-failed"))
        #expect(arbiter.arbitrate([launchPaywall]).winner == launchPaywall)
        #expect(arbiter.arbitrate([reviewPrompt]).winner == reviewPrompt)
    }
}

@MainActor
struct PresentationRecordingTests {
    @Test func arbitrationAloneStampsNothing() {
        let clock = Clock()
        let (arbiter, store) = makeArbiter(
            policies: .init(surfaceCooldowns: [launchPaywall.cooldownKey: 3600]),
            clock: clock)
        _ = arbiter.arbitrate([launchPaywall])
        #expect(store.lastPresentation(cooldownKey: launchPaywall.cooldownKey) == nil)
        #expect(arbiter.arbitrate([launchPaywall]).winner == launchPaywall)
    }

    @Test func presentedStampsBothSurfaceAndCategory() {
        let clock = Clock()
        let (arbiter, store) = makeArbiter(policies: .init(), clock: clock)
        arbiter.recordPresented(launchPaywall)
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
        #expect(store.lastPresentation(category: .promotion) == newer)

        store.seedPresentation(cooldownKey: "fresh", category: .announcement, at: older)
        #expect(store.lastPresentation(cooldownKey: "fresh") == older)
        #expect(store.lastPresentation(category: .announcement) == older)
    }

    @Test(arguments: [true, false])
    func seedingSameCategoryEndsAtNewestDateRegardlessOfOrder(newestFirst: Bool) {
        let store = UserDefaultsSurfaceStateStore(userDefaults: makeDefaults())
        let newer = Date(timeIntervalSince1970: 2_000_000)
        let older = Date(timeIntervalSince1970: 1_000_000)
        let seeds = [("surface-a", newer), ("surface-b", older)]
        for (key, date) in (newestFirst ? seeds : seeds.reversed()) {
            store.seedPresentation(cooldownKey: key, category: .promotion, at: date)
        }
        #expect(store.lastPresentation(cooldownKey: "surface-a") == newer)
        #expect(store.lastPresentation(cooldownKey: "surface-b") == older)
        #expect(store.lastPresentation(category: .promotion) == newer)
    }

    @Test func seedingAdvancesCategoryEvenWhenSurfaceIsAlreadyNewer() {
        let store = UserDefaultsSurfaceStateStore(userDefaults: makeDefaults())
        let newer = Date(timeIntervalSince1970: 2_000_000)
        let older = Date(timeIntervalSince1970: 1_000_000)
        // Explicitly construct "surface newer, category older" — the state a
        // pre-fix seeding order could leave behind: the surface already holds
        // the newer date, then another surface of the same category rewinds
        // the category record to an older date.
        store.recordPresentation(cooldownKey: "key", category: .promotion, at: newer)
        store.recordPresentation(cooldownKey: "other", category: .promotion, at: older)
        #expect(store.lastPresentation(cooldownKey: "key") == newer)
        #expect(store.lastPresentation(category: .promotion) == older)

        // Re-seeding must advance the category independently even though the
        // surface itself has nothing to update.
        store.seedPresentation(cooldownKey: "key", category: .promotion, at: newer)
        #expect(store.lastPresentation(cooldownKey: "key") == newer)
        #expect(store.lastPresentation(category: .promotion) == newer)

        // And seeding an older date rewinds neither dimension.
        store.seedPresentation(cooldownKey: "key", category: .promotion, at: older)
        #expect(store.lastPresentation(cooldownKey: "key") == newer)
        #expect(store.lastPresentation(category: .promotion) == newer)
    }
}
