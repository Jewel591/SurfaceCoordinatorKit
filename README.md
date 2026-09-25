# SurfaceCoordinatorKit

Cross-product Swift package that decides which **app-initiated** surface
(update prompt, launch paywall, announcement, What's New, review request, …)
may reach the screen, makes sure it really did, and records why every other
candidate was not shown.

Two products:

| Product | What it is |
|---|---|
| `SurfaceCoordinatorKit` | The process runtime. Pure Foundation: producer registry, pending candidates, a single presentation permit, counted occupancy, rule evaluation, outcome recording, cooldown persistence. |
| `SurfaceCoordinatorKitUI` | The SwiftUI presentation adapter, one host per window. Scene gating, sheet / cover ownership, landing confirmation, dismissal reporting. |

The Kit decides *why, when, and whether it landed*; the host app decides
*what it looks like*.

## The problem it solves

Once an app has more than two self-initiated surfaces, "which one shows this
time" becomes real business logic: an update prompt must outrank a promotion,
a review request must not follow a paywall, everything should defer while the
user is mid-flow. Without one runtime these rules become pairwise gate flags
between managers, and every app re-implements the same presentation plumbing.
That plumbing is where the worst bugs live: a sheet bound while the app runs
in the background never reaches the screen, yet `onAppear` fires, the host
records it as presented, and its "a surface is showing" flag blocks every
later surface for the rest of the process.

## Scope norm (read this first)

- **App-initiated interruptions are producers.** Anything the user did not
  ask for registers a `SurfaceProducer` and submits when it has something to
  show.
- **User-initiated presentations never become producers.** The user tapped a
  button or followed a deep link and expects the page immediately. Present
  those through the app's own presentation layer and report them as
  **occupancy** so producers wait.
- The same page may have both identities — a paywall opened from settings
  (user-initiated) vs. auto-shown at launch (app-initiated). **Reuse the page,
  split the entry points.**
- **Persistent passive UI never registers.** Badges and banners render from
  their own domain state. `SurfaceProducer` refuses the `.passive` tier.

## Ordering

Order is a fixed vocabulary, never a number:

1. **Tier** — `.blocking` (the app cannot continue) before `.interruptive`.
2. **Purpose** — inside a tier: `.attention`, `.update`, `.announcement`,
   `.monetization`, `.housekeeping`, `.engagement`.
3. **Producer id** — inside a purpose, lexicographic.

Registration order, submission order and initialization races never change
who wins.

## Usage

### 1. Configure the canonical runtime once

```swift
import SurfaceCoordinatorKit

let surfaces = SurfaceCoordinator.shared
surfaces.configure(policies: SurfacePolicySet(
    surfaceCooldowns: ["app.launch-paywall": 24 * 3600],
    sessionInterruptionBudget: 1,
    successionRules: [
        .init(previous: "promotion", next: "review", window: 6 * 3600),
    ]
))
surfaces.beginSession()
```

Every producer and every occupancy owner in production must use
`SurfaceCoordinator.shared`. The public initializer is a test seam.

### 2. Register producers

```swift
extension SurfaceProducerID {
    static let launchPaywall: SurfaceProducerID = "app.launch-paywall"
}

surfaces.register(
    SurfaceProducer(id: .whatsNew, category: "announcement", purpose: .announcement),
    onPresented: { whatsNew.markPresented() },
    onDismissed: { whatsNew.markSeen() })

surfaces.register(
    SurfaceProducer(
        id: .launchPaywall, category: "promotion",
        purpose: .monetization, style: .fullScreenCover))

surfaces.register(
    SurfaceProducer(
        id: .review, category: "review", purpose: .engagement, style: .unobservable))
```

Registration is idempotent: the first descriptor and callbacks win.
`onPresented` runs once, after the content reached the window.
`onDismissed` runs once, after a landed presentation finished dismissing.

### 3. Submit, hold back, withdraw

```swift
surfaces.submit(.whatsNew)                 // local candidate, ready now

surfaces.markPending(.appUpdate)           // remote lookup in flight
if await updateChecker.hasUpdate() {
    surfaces.submit(.appUpdate)
} else {
    surfaces.withdraw(.appUpdate)
}
```

A pending producer holds back lower-precedence producers for at most
`maxWait` (3 s by default), so a slow lookup never stalls a local candidate
for long. `withdraw` also revokes a permit whose content has not landed yet.

### 4. Host every window

```swift
import SurfaceCoordinatorKitUI

WindowGroup {
    RootView()
        .surfaceHost { id in
            switch id {
            case .whatsNew: WhatsNewView(content: whatsNew.content)
            case .launchPaywall: PaywallView(placement: .launch)
            default: EmptyView()
            }
        }
}
```

The host asks for the permit only while its scene is foreground-active and
its window presents nothing else. It confirms landing with a probe view that
must enter the window within `landingTimeout` (1.5 s) while the scene stays
active; otherwise it reports `.failed`, withdraws the presentation, and the
runtime retries after `retryDelay` up to `maxAttempts` times without writing
any cooldown. A scene that goes to the background before landing gives the
permit back and competes again on return. macOS renders covers as sheets.

### 5. Report occupancy

```swift
surfaces.setOccupied(true, by: "onboarding")
surfaces.setOccupied(false, by: "onboarding")
```

Owners are counted, so one owner releasing never releases another.
User-initiated sheets, onboarding, lock screens and account flows are
occupancy.

### 6. Unobservable system UI

```swift
surfaces.performUnobservable(.review) {
    AppStore.requestReview(in: windowScene)
}
```

Nobody can observe whether StoreKit showed anything, so an attempt stamps no
cooldown and uses no budget. It does hold back every further interruptive
producer until the next `beginSession()`.

## Outcomes

| Outcome | When | State |
|---|---|---|
| `.presented` | Content reached the window, once per permit | Stamps cooldowns, uses budget |
| `.failed` | Did not land within the timeout | Nothing stamped; bounded retry |
| `.skipped` | Withdrawn, or permit given up before landing | Nothing stamped; candidate kept unless withdrawn |
| `.attempted` | Unobservable system UI requested | Nothing stamped; no further interruptions this session |

`eventHandler` receives every lifecycle event (`SurfaceEvent`), including
not-landed details describing what the window was presenting at the time.

## Observed facts for the host

- `isPresenting` / `activeProducerID` — a producer holds the permit.
- `hasActivity` — presenting, waiting on a pending producer, or holding a
  candidate the rules would let through now. Use it to hold back tips and
  hints that must not race a surface.
- `isOccupied`.

## Companion tooling

- **Agent skill**: [`.agents/skills/integrate-surfacecoordinatorkit`](.agents/skills/integrate-surfacecoordinatorkit/SKILL.md).
- **Adoption lint**: `surface-coordinator-kit-lint` in
  [product-playbook](https://github.com/Jewel591/product-playbook) `scripts/`.

## Engineering

- Swift 6 strict concurrency; the runtime and stores are `@MainActor`.
- iOS 17, macOS 14, visionOS 1. watchOS does not link the adapter.
- Zero third-party dependencies. The core imports no UI framework.
- Rule, runtime and adapter-contract behavior is covered by package tests in
  `Tests/SurfaceCoordinatorKitTests`.
