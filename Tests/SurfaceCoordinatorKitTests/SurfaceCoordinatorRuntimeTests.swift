import Foundation
import Testing

@testable import SurfaceCoordinatorKit

@MainActor
private final class Clock {
    var current = Date(timeIntervalSince1970: 1_000_000)
    func advance(_ interval: TimeInterval) { current += interval }
}

private let update = SurfaceProducer(
    id: .appUpdate, category: "update", purpose: .update)
private let whatsNew = SurfaceProducer(
    id: .whatsNew, category: "announcement", purpose: .announcement)
private let paywall = SurfaceProducer(
    id: "app.launch-paywall", category: "promotion", purpose: .monetization,
    style: .fullScreenCover)
private let review = SurfaceProducer(
    id: .review, category: "review", purpose: .engagement, style: .unobservable)
private let forcedUpdate = SurfaceProducer(
    id: "app.forced-update", category: "update", tier: .blocking, purpose: .update)

@MainActor
private struct Harness {
    let clock = Clock()
    let store = InMemorySurfaceStateStore()
    let coordinator: SurfaceCoordinator
    let scene = UUID()
    let otherScene = UUID()

    init(budget: Int = 10, cooldowns: [String: TimeInterval] = [:]) {
        let clock = clock
        coordinator = SurfaceCoordinator(
            policies: SurfacePolicySet(
                surfaceCooldowns: cooldowns, sessionInterruptionBudget: budget),
            store: store,
            now: { clock.current })
        for producer in [update, whatsNew, paywall, review, forcedUpdate] {
            coordinator.register(producer)
        }
    }

    func grant(_ scene: UUID? = nil) -> SurfacePermit? {
        guard case .granted(let permit) = coordinator.requestPermit(scene: scene ?? self.scene)
        else { return nil }
        return permit
    }

    /// Grants, lands and dismisses the next winner.
    func presentAndDismiss() -> SurfacePermit? {
        guard let permit = grant() else { return nil }
        coordinator.confirmPresented(permit)
        coordinator.completeDismissal(permit)
        return permit
    }
}

@MainActor
struct RegistryTests {
    @Test func registrationIsIdempotentAndKeepsFirstDescriptor() {
        let coordinator = SurfaceCoordinator(store: InMemorySurfaceStateStore())
        var firstCalls = 0
        var secondCalls = 0
        coordinator.register(whatsNew, onPresented: { firstCalls += 1 })
        coordinator.register(
            SurfaceProducer(id: .whatsNew, category: "other", purpose: .engagement),
            onPresented: { secondCalls += 1 })

        #expect(coordinator.producer(.whatsNew) == whatsNew)
        coordinator.submit(.whatsNew)
        guard case .granted(let permit) = coordinator.requestPermit(scene: UUID()) else {
            Issue.record("expected a grant")
            return
        }
        coordinator.confirmPresented(permit)
        #expect(firstCalls == 1)
        #expect(secondCalls == 0)
    }

    @Test(arguments: [true, false])
    func orderIgnoresRegistrationAndSubmissionOrder(reversed: Bool) {
        let coordinator = SurfaceCoordinator(store: InMemorySurfaceStateStore())
        let producers = reversed ? [paywall, whatsNew] : [whatsNew, paywall]
        for producer in producers { coordinator.register(producer) }
        for producer in producers.reversed() { coordinator.submit(producer.id) }

        guard case .granted(let permit) = coordinator.requestPermit(scene: UUID()) else {
            Issue.record("expected a grant")
            return
        }
        #expect(permit.producer == whatsNew)
    }

    @Test func unregisteredAndUnobservableSubmissionsAreIgnored() {
        let harness = Harness()
        harness.coordinator.submit("app.unknown")
        harness.coordinator.submit(.review)
        #expect(harness.coordinator.requestPermit(scene: harness.scene) == .unavailable)
    }
}

@MainActor
struct PendingCandidateTests {
    @Test func pendingHigherPrecedenceHoldsBackLowerUntilItResolves() {
        let harness = Harness()
        harness.coordinator.markPending(.appUpdate, maxWait: 3)
        harness.coordinator.submit(.whatsNew)

        #expect(harness.coordinator.requestPermit(scene: harness.scene) == .retry(after: 3))
        #expect(harness.coordinator.hasActivity)

        harness.coordinator.submit(.appUpdate)
        #expect(harness.grant()?.producer == update)
    }

    @Test func expiredPendingStopsHoldingBackAndStopsReportingActivity() {
        let harness = Harness()
        harness.coordinator.markPending(.appUpdate, maxWait: 3)
        harness.clock.advance(1)
        #expect(harness.coordinator.requestPermit(scene: harness.scene) == .retry(after: 2))

        harness.clock.advance(2)
        #expect(harness.coordinator.requestPermit(scene: harness.scene) == .unavailable)
        #expect(!harness.coordinator.hasActivity)

        harness.coordinator.submit(.whatsNew)
        #expect(harness.grant()?.producer == whatsNew)
    }

    @Test func pendingLowerPrecedenceNeverHoldsBackHigher() {
        let harness = Harness()
        harness.coordinator.markPending(.whatsNew)
        harness.coordinator.submit(.appUpdate)
        #expect(harness.grant()?.producer == update)
    }

    @Test func withdrawDropsCandidate() {
        let harness = Harness()
        harness.coordinator.submit(.whatsNew)
        harness.coordinator.withdraw(.whatsNew)
        #expect(harness.coordinator.requestPermit(scene: harness.scene) == .unavailable)
    }

    @Test func withdrawRevokesUnlandedPermitButKeepsLandedOne() {
        let harness = Harness()
        harness.coordinator.submit(.whatsNew)
        let unlanded = harness.grant()
        harness.coordinator.withdraw(.whatsNew)
        #expect(!harness.coordinator.isPresenting)
        #expect(unlanded.map(harness.coordinator.isCurrent) == false)

        harness.coordinator.submit(.whatsNew)
        guard let landed = harness.grant() else {
            Issue.record("expected a grant")
            return
        }
        harness.coordinator.confirmPresented(landed)
        harness.coordinator.withdraw(.whatsNew)
        #expect(harness.coordinator.isCurrent(landed))
    }
}

@MainActor
struct PermitTests {
    @Test func onlyOnePermitAcrossScenes() {
        let harness = Harness()
        harness.coordinator.submit(.whatsNew)
        harness.coordinator.submit(.appUpdate)
        #expect(harness.grant() != nil)
        #expect(harness.coordinator.requestPermit(scene: harness.otherScene) == .unavailable)
    }

    @Test func staleGenerationCannotActOnLaterPermit() {
        let harness = Harness(cooldowns: [SurfaceProducerID.whatsNew.rawValue: 3600])
        harness.coordinator.submit(.whatsNew)
        guard let stale = harness.grant() else {
            Issue.record("expected a grant")
            return
        }
        harness.coordinator.abandon(stale)
        guard let current = harness.grant() else {
            Issue.record("expected a second grant")
            return
        }
        #expect(current.generation > stale.generation)

        harness.coordinator.confirmPresented(stale)
        harness.coordinator.reportNotLanded(stale)
        harness.coordinator.completeDismissal(stale)
        #expect(harness.coordinator.isCurrent(current))
        #expect(!harness.coordinator.isLanded(current))
        #expect(harness.store.lastPresentation(cooldownKey: whatsNew.cooldownKey) == nil)
    }

    @Test func abandonedPermitKeepsCandidateWithoutStamping() {
        let harness = Harness(cooldowns: [SurfaceProducerID.whatsNew.rawValue: 3600])
        harness.coordinator.submit(.whatsNew)
        guard let permit = harness.grant() else {
            Issue.record("expected a grant")
            return
        }
        harness.coordinator.abandon(permit)

        #expect(harness.store.lastPresentation(cooldownKey: whatsNew.cooldownKey) == nil)
        #expect(harness.grant()?.producer == whatsNew)
    }
}

@MainActor
struct OccupancyTests {
    @Test func occupancyIsCountedByOwner() {
        let harness = Harness()
        harness.coordinator.submit(.whatsNew)
        harness.coordinator.setOccupied(true, by: "sheet.scene-a")
        harness.coordinator.setOccupied(true, by: "sheet.scene-a")
        harness.coordinator.setOccupied(true, by: "onboarding")
        #expect(harness.coordinator.requestPermit(scene: harness.scene) == .unavailable)

        harness.coordinator.setOccupied(false, by: "sheet.scene-a")
        #expect(harness.coordinator.isOccupied)
        #expect(harness.coordinator.requestPermit(scene: harness.scene) == .unavailable)

        harness.coordinator.setOccupied(false, by: "onboarding")
        #expect(harness.grant()?.producer == whatsNew)
    }

    @Test func releasingUnknownOwnerChangesNothing() {
        let harness = Harness()
        harness.coordinator.setOccupied(true, by: "onboarding")
        let revision = harness.coordinator.revision
        harness.coordinator.setOccupied(false, by: "sheet")
        #expect(harness.coordinator.revision == revision)
        #expect(harness.coordinator.isOccupied)
    }
}

@MainActor
struct OutcomeTests {
    @Test func presentedRecordsOncePerPermit() {
        let harness = Harness(budget: 1)
        var presentedCalls = 0
        let coordinator = SurfaceCoordinator(
            policies: SurfacePolicySet(sessionInterruptionBudget: 1),
            store: harness.store, now: { harness.clock.current })
        coordinator.register(whatsNew, onPresented: { presentedCalls += 1 })
        coordinator.register(paywall)
        coordinator.submit(.whatsNew)
        coordinator.submit(paywall.id)

        guard case .granted(let permit) = coordinator.requestPermit(scene: harness.scene) else {
            Issue.record("expected a grant")
            return
        }
        coordinator.confirmPresented(permit)
        coordinator.confirmPresented(permit)
        #expect(presentedCalls == 1)
        #expect(harness.store.lastPresentation(cooldownKey: whatsNew.cooldownKey) == harness.clock.current)

        // One presentation used the budget of one: the paywall waits.
        coordinator.completeDismissal(permit)
        #expect(coordinator.requestPermit(scene: harness.scene) == .unavailable)
        #expect(coordinator.isSubmitted(paywall.id))
    }

    @Test func dismissalReleasesOnlyAfterLandingAndOnce() {
        let harness = Harness()
        var dismissedCalls = 0
        let coordinator = SurfaceCoordinator(store: harness.store)
        coordinator.register(whatsNew, onDismissed: { dismissedCalls += 1 })
        coordinator.submit(.whatsNew)
        guard case .granted(let permit) = coordinator.requestPermit(scene: harness.scene) else {
            Issue.record("expected a grant")
            return
        }

        coordinator.completeDismissal(permit)
        #expect(coordinator.isPresenting)
        #expect(dismissedCalls == 0)

        coordinator.confirmPresented(permit)
        coordinator.completeDismissal(permit)
        coordinator.completeDismissal(permit)
        #expect(!coordinator.isPresenting)
        #expect(dismissedCalls == 1)
        #expect(!coordinator.isSubmitted(.whatsNew))
    }

    @Test func notLandedRetriesAfterDelayWithoutStampingThenGivesUp() {
        let harness = Harness(cooldowns: [SurfaceProducerID.whatsNew.rawValue: 3600])
        var events: [SurfaceEvent] = []
        harness.coordinator.eventHandler = { events.append($0) }
        harness.coordinator.submit(.whatsNew)

        for attempt in 1...3 {
            guard let permit = harness.grant() else {
                Issue.record("expected grant for attempt \(attempt)")
                return
            }
            harness.coordinator.reportNotLanded(permit, detail: "Blocker")
            #expect(!harness.coordinator.isPresenting)
            if attempt < 3 {
                #expect(harness.coordinator.requestPermit(scene: harness.scene) == .retry(after: 0.5))
                harness.clock.advance(0.5)
            }
        }

        #expect(harness.store.lastPresentation(cooldownKey: whatsNew.cooldownKey) == nil)
        harness.clock.advance(0.5)
        #expect(harness.coordinator.requestPermit(scene: harness.scene) == .unavailable)
        #expect(!harness.coordinator.isSubmitted(.whatsNew))
        #expect(events.contains(.notLanded(whatsNew, attempt: 3, isFinal: true, detail: "Blocker")))
        #expect(events.filter { $0.outcome == .failed }.count == 3)

        // A fresh submission competes again.
        harness.coordinator.submit(.whatsNew)
        #expect(harness.grant()?.producer == whatsNew)
    }

    @Test func attemptedReleasesWithoutStampingAndHoldsBackFurtherInterruptions() {
        let harness = Harness(cooldowns: [SurfaceProducerID.review.rawValue: 3600])
        var performed = 0
        #expect(harness.coordinator.performUnobservable(.review) { performed += 1 })
        #expect(performed == 1)
        #expect(!harness.coordinator.isPresenting)
        #expect(harness.store.lastPresentation(cooldownKey: review.cooldownKey) == nil)

        harness.coordinator.submit(.whatsNew)
        #expect(harness.coordinator.requestPermit(scene: harness.scene) == .unavailable)
        #expect(!harness.coordinator.performUnobservable(.review) { performed += 1 })
        #expect(performed == 1)

        harness.coordinator.submit(forcedUpdate.id)
        #expect(harness.grant()?.producer == forcedUpdate)
    }

    @Test func attemptedHoldLiftsOnNewSession() {
        let harness = Harness()
        harness.coordinator.performUnobservable(.review) {}
        harness.coordinator.submit(.whatsNew)
        harness.coordinator.beginSession()
        #expect(harness.grant()?.producer == whatsNew)
    }

    @Test func unobservableWaitsForPermitOccupancyAndHigherCandidates() {
        let harness = Harness()
        var performed = 0

        harness.coordinator.submit(.whatsNew)
        #expect(!harness.coordinator.performUnobservable(.review) { performed += 1 })

        let permit = harness.grant()
        #expect(!harness.coordinator.performUnobservable(.review) { performed += 1 })
        if let permit {
            harness.coordinator.confirmPresented(permit)
            harness.coordinator.completeDismissal(permit)
        }

        harness.coordinator.setOccupied(true, by: "sheet")
        #expect(!harness.coordinator.performUnobservable(.review) { performed += 1 })
        harness.coordinator.setOccupied(false, by: "sheet")

        #expect(harness.coordinator.performUnobservable(.review) { performed += 1 })
        #expect(performed == 1)
    }
}

@MainActor
struct ActivityTests {
    @Test func candidateInCooldownIsNotActivity() {
        let harness = Harness(cooldowns: [SurfaceProducerID.whatsNew.rawValue: 3600])
        harness.coordinator.submit(.whatsNew)
        #expect(harness.coordinator.hasActivity)
        _ = harness.presentAndDismiss()
        harness.coordinator.submit(.whatsNew)
        #expect(!harness.coordinator.hasActivity)
    }

    @Test func presentingIsActivity() {
        let harness = Harness()
        harness.coordinator.submit(.whatsNew)
        _ = harness.grant()
        #expect(harness.coordinator.isPresenting)
        #expect(harness.coordinator.hasActivity)
        #expect(harness.coordinator.activeProducerID == .whatsNew)
    }
}

struct LaneBoundaryTests {
    @Test func passiveProducersAreRejected() async {
        await #expect(processExitsWith: .failure) {
            _ = SurfaceProducer(id: "app.banner", category: "promotion", tier: .passive, purpose: .monetization)
        }
    }
}
