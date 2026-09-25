import Foundation
import Observation
import OSLog

/// The process-wide runtime that decides which **app-initiated** surface, if
/// any, may reach the screen.
///
/// ## Scope norm (the contract this Kit exists to enforce)
///
/// - **App-initiated interruptions are producers.** Update prompts, launch
///   paywalls, announcements, What's New, review requests, recovery notices —
///   anything the user did not ask for — register a `SurfaceProducer` and
///   submit when they have something to show.
/// - **User-initiated presentations never become producers.** When the user
///   taps a button or follows a deep link they expect the page immediately.
///   Present it through the app's own presentation layer and report it as
///   occupancy (`setOccupied(_:by:)`) so producers wait.
/// - **Persistent passive UI never registers.** Badges and banners render
///   from their own domain state; they do not compete for the modal permit.
///
/// ## Division of labor
///
/// The runtime owns *why and when*: candidate bookkeeping, a single
/// presentation permit, occupancy, rule evaluation and outcome recording.
/// The SwiftUI adapter in `SurfaceCoordinatorKitUI` owns *whether it really
/// reached the screen*: scene gating, sheet / cover ownership, landing
/// confirmation and dismissal. The host owns *what it looks like* (content
/// views), *the parameters* (`SurfacePolicySet`) and blocking facts the Kit
/// cannot derive.
///
/// ## One runtime per process
///
/// Production code uses `SurfaceCoordinator.shared`. Every producer and every
/// occupancy owner must reach the same instance, otherwise two runtimes each
/// grant a permit. The public initializer exists as a test seam.
@MainActor
@Observable
public final class SurfaceCoordinator {
    /// The canonical process runtime.
    public static let shared = SurfaceCoordinator()

    /// Timing of the landing contract between runtime and adapter.
    public struct LandingPolicy: Sendable, Equatable {
        /// How long the adapter waits, while its scene stays active, for the
        /// content to reach the window before reporting it as not landed.
        public var landingTimeout: TimeInterval

        /// Delay before a producer that did not land may be granted again.
        public var retryDelay: TimeInterval

        /// Not-landed reports after which the candidate is dropped for this
        /// process. It stays eligible after the next `submit`.
        public var maxAttempts: Int

        public init(landingTimeout: TimeInterval = 1.5, retryDelay: TimeInterval = 0.5, maxAttempts: Int = 3) {
            self.landingTimeout = landingTimeout
            self.retryDelay = retryDelay
            self.maxAttempts = maxAttempts
        }
    }

    /// How long a pending candidate may hold back lower-precedence producers
    /// when `markPending` is called without an explicit wait.
    public static let defaultPendingWait: TimeInterval = 3

    // MARK: - State

    private struct Registration {
        let producer: SurfaceProducer
        let onPresented: (@MainActor () -> Void)?
        let onDismissed: (@MainActor () -> Void)?
    }

    private struct ActivePermit {
        let permit: SurfacePermit
        var landed: Bool
    }

    @ObservationIgnored private let arbiter: SurfaceArbiter
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let logger = Logger(
        subsystem: "SurfaceCoordinatorKit", category: "SurfaceCoordinator")
    @ObservationIgnored private var registrations: [SurfaceProducerID: Registration] = [:]
    @ObservationIgnored private var failures: [SurfaceProducerID: Int] = [:]
    @ObservationIgnored private var nextGeneration: UInt64 = 0

    /// Pending candidates and the moment they stop holding back others.
    private var pending: [SurfaceProducerID: Date] = [:]
    private var ready: Set<SurfaceProducerID> = []
    private var active: ActivePermit?
    private var occupants: Set<String> = []
    private var attemptedThisSession = false
    private var retryNotBefore: Date?

    /// Bumped on every state change the adapter must react to. Adapters
    /// re-evaluate when it changes; nothing else should read it.
    package private(set) var revision: UInt64 = 0

    public private(set) var landingPolicy = LandingPolicy()

    /// Receives every lifecycle event, for logging and diagnostics.
    @ObservationIgnored public var eventHandler: (@MainActor (SurfaceEvent) -> Void)?

    public init(
        policies: SurfacePolicySet = SurfacePolicySet(),
        store: SurfaceStateStoring? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.arbiter = SurfaceArbiter(
            policies: policies, store: store ?? UserDefaultsSurfaceStateStore(), now: now)
        self.now = now
    }

    /// Installs the app's policy set. Call once at launch, before the first
    /// producer submits.
    public func configure(policies: SurfacePolicySet, landing: LandingPolicy = LandingPolicy()) {
        arbiter.policies = policies
        landingPolicy = landing
        bump()
    }

    /// The presentation history store, for one-time legacy seeding.
    public var store: SurfaceStateStoring { arbiter.store }

    // MARK: - Observed facts

    /// A producer holds the permit (granted, landed or not yet dismissed).
    public var isPresenting: Bool {
        active != nil
    }

    /// The producer currently holding the permit.
    public var activeProducerID: SurfaceProducerID? {
        active?.permit.producer.id
    }

    /// Whether the runtime is presenting, waiting on a pending producer, or
    /// holds a candidate the rules would let through now. Hosts use it to
    /// hold back lightweight UI (tips, hints) that must not race a surface.
    public var hasActivity: Bool {
        if active != nil { return true }
        let date = now()
        if pending.values.contains(where: { $0 > date }) { return true }
        return arbitrateReady().winner != nil
    }

    /// Whether any occupancy owner is registered.
    public var isOccupied: Bool {
        !occupants.isEmpty
    }

    // MARK: - Session

    /// Starts a foreground session: resets the interruption budget and lifts
    /// the no-further-interruption hold left by an unobservable attempt. The
    /// host decides what counts as a new session.
    public func beginSession() {
        arbiter.beginSession()
        attemptedThisSession = false
        bump()
    }

    // MARK: - Registry

    /// Registers a producer. Idempotent: registering the same id again keeps
    /// the first descriptor and callbacks, so initialization order never
    /// changes behavior. Order between producers comes from the descriptor,
    /// never from registration order.
    ///
    /// - Parameters:
    ///   - onPresented: Runs once when the adapter confirms the content
    ///     reached the window.
    ///   - onDismissed: Runs once when a landed presentation finished
    ///     dismissing (including its window closing).
    public func register(
        _ producer: SurfaceProducer,
        onPresented: (@MainActor () -> Void)? = nil,
        onDismissed: (@MainActor () -> Void)? = nil
    ) {
        if let existing = registrations[producer.id] {
            if existing.producer != producer {
                logger.error(
                    "producer \(producer.id.rawValue, privacy: .public) registered twice with different descriptors; keeping the first")
            }
            return
        }
        registrations[producer.id] = Registration(
            producer: producer, onPresented: onPresented, onDismissed: onDismissed)
    }

    /// The registered descriptor for an id.
    public func producer(_ id: SurfaceProducerID) -> SurfaceProducer? {
        registrations[id]?.producer
    }

    // MARK: - Candidates

    /// Declares that a producer is still deciding (a remote lookup is in
    /// flight). While pending, it holds back lower-precedence producers for
    /// at most `maxWait`; after that others proceed and this producer can
    /// still `submit` later.
    public func markPending(_ id: SurfaceProducerID, maxWait: TimeInterval = defaultPendingWait) {
        guard registered(id) else { return }
        pending[id] = now().addingTimeInterval(maxWait)
        bump()
    }

    /// Declares that a producer has something to show. Idempotent.
    public func submit(_ id: SurfaceProducerID) {
        guard let producer = registrations[id]?.producer else {
            logger.error("submit for unregistered producer \(id.rawValue, privacy: .public)")
            return
        }
        guard producer.style != .unobservable else {
            logger.error(
                "unobservable producer \(id.rawValue, privacy: .public) must use performUnobservable")
            return
        }
        pending.removeValue(forKey: id)
        if ready.insert(id).inserted {
            failures.removeValue(forKey: id)
        }
        bump()
    }

    /// Declares that a producer no longer has anything to show. Revokes its
    /// permit if the content has not reached the screen yet; a landed
    /// presentation stays until the user dismisses it.
    public func withdraw(_ id: SurfaceProducerID) {
        let hadCandidate = pending.removeValue(forKey: id) != nil || ready.remove(id) != nil
        failures.removeValue(forKey: id)
        if let current = active, current.permit.producer.id == id, !current.landed {
            active = nil
            emit(.withdrawn(current.permit.producer))
        } else if hadCandidate, let producer = registrations[id]?.producer {
            emit(.withdrawn(producer))
        }
        bump()
    }

    /// Whether a producer is currently submitted.
    public func isSubmitted(_ id: SurfaceProducerID) -> Bool {
        ready.contains(id)
    }

    // MARK: - Occupancy

    /// Reports that something the runtime cannot see is on screen — a
    /// user-initiated sheet, onboarding, a lock screen, a system prompt.
    /// Owners are counted: occupancy lasts until every owner released, so
    /// one scene clearing its owner never releases another scene's.
    public func setOccupied(_ occupied: Bool, by owner: String) {
        let changed = occupied ? occupants.insert(owner).inserted : occupants.remove(owner) != nil
        if changed { bump() }
    }

    // MARK: - Context signals

    /// Registers an opaque context signal, optionally self-expiring.
    /// Suppression rules in the policy set reference signal keys.
    public func registerSignal(_ key: String, expiresAfter: TimeInterval? = nil) {
        arbiter.registerSignal(key, expiresAfter: expiresAfter)
        bump()
    }

    public func clearSignal(_ key: String) {
        arbiter.clearSignal(key)
        bump()
    }

    /// Clears every registered context signal. Does not reset the session.
    public func clearAllSignals() {
        arbiter.clearAllSignals()
        bump()
    }

    public func isSignalActive(_ key: String) -> Bool {
        arbiter.isSignalActive(key)
    }

    // MARK: - Unobservable system UI

    /// Runs `perform` for an `.unobservable` producer (a StoreKit review
    /// request) if it may interrupt now, and records an attempt.
    ///
    /// An attempt never stamps presented cooldowns and never uses the
    /// session budget, because nobody can observe whether the system showed
    /// anything. It does hold back every further interruptive producer until
    /// the next `beginSession()`, so no second modal lands on top of a
    /// possible system prompt.
    ///
    /// - Returns: Whether `perform` ran.
    @discardableResult
    public func performUnobservable(
        _ id: SurfaceProducerID, perform: @MainActor () -> Void
    ) -> Bool {
        guard let producer = registrations[id]?.producer, producer.style == .unobservable else {
            logger.error("performUnobservable for non-unobservable producer \(id.rawValue, privacy: .public)")
            return false
        }
        guard active == nil, occupants.isEmpty else { return false }
        if producer.tier == .interruptive, attemptedThisSession { return false }

        var candidates = readyCandidates()
        candidates.append(producer)
        let arbitration = arbiter.arbitrate(candidates)
        log(arbitration)
        guard arbitration.winner?.id == id, !isHeldBackByPending(producer) else { return false }

        perform()
        if producer.tier == .interruptive {
            attemptedThisSession = true
        }
        emit(.attempted(producer))
        bump()
        return true
    }

    // MARK: - Adapter contract

    /// Asks for the single presentation permit on behalf of one scene.
    package func requestPermit(scene: UUID) -> SurfacePermitDecision {
        let date = now()
        prunePending(at: date)
        guard active == nil, occupants.isEmpty else { return .unavailable }
        if let retryNotBefore, retryNotBefore > date {
            return .retry(after: retryNotBefore.timeIntervalSince(date))
        }
        let arbitration = arbitrateReady()
        guard let winner = arbitration.winner else {
            // Wake up when the earliest pending wait ends, so expired
            // pending entries stop reporting activity.
            return pending.values.min().map { .retry(after: $0.timeIntervalSince(date)) }
                ?? .unavailable
        }
        if let wait = pendingWait(before: winner, at: date) {
            return .retry(after: wait)
        }
        log(arbitration)

        nextGeneration += 1
        let permit = SurfacePermit(producer: winner, generation: nextGeneration, scene: scene)
        active = ActivePermit(permit: permit, landed: false)
        emit(.granted(winner))
        bump()
        return .granted(permit)
    }

    /// The live permit, if any.
    package var activePermit: SurfacePermit? {
        active?.permit
    }

    /// Whether `permit` is still the live one.
    package func isCurrent(_ permit: SurfacePermit) -> Bool {
        active?.permit == permit
    }

    /// Whether the live permit reached the screen.
    package func isLanded(_ permit: SurfacePermit) -> Bool {
        guard let active, active.permit == permit else { return false }
        return active.landed
    }

    /// The content reached the target window. Records `.presented` once per
    /// permit; later calls and stale permits are ignored.
    package func confirmPresented(_ permit: SurfacePermit) {
        guard var current = active, current.permit == permit, !current.landed else { return }
        current.landed = true
        active = current
        let producer = permit.producer
        arbiter.recordPresented(producer)
        ready.remove(producer.id)
        failures.removeValue(forKey: producer.id)
        emit(.presented(producer))
        registrations[producer.id]?.onPresented?()
        bump()
    }

    /// The content did not reach the window in time. Records `.failed`:
    /// releases the permit without touching cooldowns, delays the next grant
    /// and drops the candidate after `maxAttempts`.
    package func reportNotLanded(_ permit: SurfacePermit, detail: String? = nil) {
        guard let current = active, current.permit == permit, !current.landed else { return }
        active = nil
        let producer = permit.producer
        let attempts = (failures[producer.id] ?? 0) + 1
        let isFinal = attempts >= landingPolicy.maxAttempts
        if isFinal {
            ready.remove(producer.id)
            failures.removeValue(forKey: producer.id)
        } else {
            failures[producer.id] = attempts
        }
        retryNotBefore = now().addingTimeInterval(landingPolicy.retryDelay)
        emit(.notLanded(producer, attempt: attempts, isFinal: isFinal, detail: detail))
        bump()
    }

    /// A landed presentation finished dismissing. Releases the permit once.
    package func completeDismissal(_ permit: SurfacePermit) {
        guard let current = active, current.permit == permit, current.landed else { return }
        active = nil
        emit(.dismissed(permit.producer))
        registrations[permit.producer.id]?.onDismissed?()
        bump()
    }

    /// The permit is given up before landing (its scene left the foreground
    /// or its window closed). Records `.skipped`: the candidate stays
    /// submitted and competes again.
    package func abandon(_ permit: SurfacePermit) {
        guard let current = active, current.permit == permit, !current.landed else { return }
        active = nil
        emit(.abandoned(permit.producer))
        bump()
    }

    // MARK: - Helpers

    private func registered(_ id: SurfaceProducerID) -> Bool {
        guard registrations[id] != nil else {
            logger.error("unregistered producer \(id.rawValue, privacy: .public)")
            return false
        }
        return true
    }

    private func readyCandidates() -> [SurfaceProducer] {
        ready.compactMap { registrations[$0]?.producer }.filter { producer in
            !(attemptedThisSession && producer.tier == .interruptive)
        }
    }

    private func arbitrateReady() -> SurfaceArbitration {
        arbiter.arbitrate(readyCandidates())
    }

    /// Remaining wait while a pending producer that precedes `producer` is
    /// still deciding.
    private func pendingWait(before producer: SurfaceProducer, at date: Date) -> TimeInterval? {
        let waits = pending.compactMap { id, deadline -> TimeInterval? in
            guard deadline > date, let other = registrations[id]?.producer,
                other.precedes(producer) else { return nil }
            return deadline.timeIntervalSince(date)
        }
        return waits.max()
    }

    private func prunePending(at date: Date) {
        let expired = pending.filter { $0.value <= date }.map(\.key)
        guard !expired.isEmpty else { return }
        for id in expired { pending.removeValue(forKey: id) }
        bump()
    }

    private func isHeldBackByPending(_ producer: SurfaceProducer) -> Bool {
        pendingWait(before: producer, at: now()) != nil
    }

    private func bump() {
        revision &+= 1
    }

    private func emit(_ event: SurfaceEvent) {
        logger.debug("\(String(describing: event), privacy: .public)")
        eventHandler?(event)
    }

    private func log(_ arbitration: SurfaceArbitration) {
        logger.debug("arbitration: \(arbitration.summary, privacy: .public)")
    }
}

/// Permission for one scene to present one producer. A new grant always
/// carries a new generation, so callbacks from an earlier attempt can never
/// act on a later one.
package struct SurfacePermit: Hashable, Sendable {
    package let producer: SurfaceProducer
    package let generation: UInt64
    package let scene: UUID
}

package enum SurfacePermitDecision: Equatable, Sendable {
    case granted(SurfacePermit)
    /// Something may become grantable after the delay without any other
    /// state change (a retry delay or a pending producer's wait).
    case retry(after: TimeInterval)
    /// Nothing grantable until state changes.
    case unavailable
}

/// Lifecycle events, for host logging and diagnostics.
public enum SurfaceEvent: Sendable, Equatable, CustomStringConvertible {
    /// A scene received the permit for this producer.
    case granted(SurfaceProducer)

    /// The content reached the window. Outcome `.presented`.
    case presented(SurfaceProducer)

    /// The content did not reach the window in time. Outcome `.failed`.
    /// `isFinal` means the candidate was dropped after the last attempt.
    /// `detail` describes what the platform was presenting at the time.
    case notLanded(SurfaceProducer, attempt: Int, isFinal: Bool, detail: String?)

    /// A landed presentation finished dismissing.
    case dismissed(SurfaceProducer)

    /// The permit was given up before landing. Outcome `.skipped`.
    case abandoned(SurfaceProducer)

    /// The producer withdrew its candidate. Outcome `.skipped`.
    case withdrawn(SurfaceProducer)

    /// Unobservable system UI was requested. Outcome `.attempted`.
    case attempted(SurfaceProducer)

    public var outcome: SurfaceOutcome? {
        switch self {
        case .presented: .presented
        case .notLanded: .failed
        case .abandoned, .withdrawn: .skipped
        case .attempted: .attempted
        case .granted, .dismissed: nil
        }
    }

    public var description: String {
        switch self {
        case .granted(let producer): "granted \(producer.id)"
        case .presented(let producer): "presented \(producer.id)"
        case .notLanded(let producer, let attempt, let isFinal, let detail):
            "not landed \(producer.id) attempt=\(attempt) final=\(isFinal) detail=\(detail ?? "none")"
        case .dismissed(let producer): "dismissed \(producer.id)"
        case .abandoned(let producer): "abandoned \(producer.id)"
        case .withdrawn(let producer): "withdrawn \(producer.id)"
        case .attempted(let producer): "attempted \(producer.id)"
        }
    }
}
