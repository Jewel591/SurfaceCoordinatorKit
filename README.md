# SurfaceCoordinatorKit

Cross-product Swift package that arbitrates which **app-initiated** surface
(forced update, launch paywall, promotion, announcement, review prompt, …) is
shown next — and records why every other candidate was not.

Pure Foundation, no UI. The Kit decides *why and when*; the host app decides
*what it looks like*.

## The problem it solves

Once an app has more than two self-initiated surfaces, "which one shows this
time" becomes real business logic: a forced update must outrank a promotion, a
review prompt must not follow a paywall, two promotions need hours between
them, everything should defer while the user is mid-flow. Without a single
arbiter, these rules get hand-written as pairwise gate flags between managers
(one per surface pair — they multiply quadratically and each one is a latent
race). This Kit replaces those gates with one policy evaluation that always
returns a reasoned verdict per candidate.

## Scope norm (read this first)

- **App-initiated interruptions go through the coordinator.** Anything the
  user did not ask for: update prompts, launch paywalls, promotions,
  announcements, What's New, review prompts, recovery hints.
- **User-initiated presentations never go through it.** The user tapped a
  button or followed a deep link and expects the page immediately; arbitrating
  (and possibly denying) that is a bug. Present those directly through the
  app's own presentation layer.
- The same page may have both identities — a paywall opened from settings
  (user-initiated) vs. auto-shown at launch (app-initiated). **Reuse the page,
  split the entry points**: only the app-initiated entry is arbitrated.
- User-initiated activity still *informs* arbitration: report it as a context
  signal so app-initiated surfaces defer while the user is busy.

## Division of labor

| The Kit owns | The host app owns |
|---|---|
| Rule primitives: tier ordering, cooldowns, session budget, succession bans, signal suppressions | Rule parameters: which categories exist, which intervals, which signals veto what (`SurfacePolicySet`) |
| Evaluation with a reasoned verdict per candidate | Rendering: full-screen page, sheet, or banner per surface |
| Outcome recording and cooldown persistence | Serializing actual presentation (the app's sheet queue stays) |

Tiers are a fixed vocabulary (`.blocking` / `.interruptive` / `.passive`),
deliberately not arbitrary numeric priorities. Within a tier, the order the
host lists candidates in is their precedence.

## Usage

```swift
import SurfaceCoordinatorKit

extension SurfaceCategory {
    static let update: SurfaceCategory = "update"
    static let promotion: SurfaceCategory = "promotion"
    static let review: SurfaceCategory = "review"
}

let coordinator = SurfaceCoordinator(policies: SurfacePolicySet(
    surfaceCooldowns: ["app.launch-paywall": 24 * 3600],
    categoryCooldowns: [.promotion: 48 * 3600],
    sessionInterruptionBudget: 1,
    successionRules: [
        .init(previous: .promotion, next: .review, window: 6 * 3600),
    ],
    suppressionRules: [
        .init(signalKey: "user-sheet-visible"),
        .init(signalKey: "purchase-failed", categories: [.review]),
        .init(signalKey: "system-dialog", appliesToBlocking: true),
    ]
))

// On launch / foreground:
coordinator.beginSession()

// Business features produce candidates; the coordinator picks at most one.
let arbitration = coordinator.arbitrate([
    SurfaceRequest(id: "app.forced-update", category: .update, tier: .blocking),
    SurfaceRequest(id: "app.launch-paywall", category: .promotion, tier: .interruptive),
    SurfaceRequest(id: "app.review-prompt", category: .review, tier: .interruptive),
])

if let winner = arbitration.winner {
    let shown = await appRenderer.present(winner)   // host-owned rendering
    coordinator.recordOutcome(shown ? .presented : .skipped, for: winner)
}
```

Key behaviors:

- `arbitrate` stamps nothing — only `recordOutcome(.presented, ...)` affects
  future rounds. Never report `.presented` for a surface that did not actually
  reach the screen.
- Every candidate gets a verdict with a machine-readable rejection reason;
  `arbitration.summary` is a single log-friendly line, and the coordinator
  also logs each round via `os.Logger`. "Why didn't X show" is answerable from
  logs, always.
- Context signals are opaque keys with optional expiry
  (`registerSignal("critical-flow", expiresAfter: 300)`); the Kit never needs
  to know what a key means.
- `UserDefaultsSurfaceStateStore.seedPresentation(...)` migrates a legacy
  "last shown" date once, so existing users keep their cooldown position.

## Companion tooling

- **Agent skill**: [`.agents/skills/integrate-surfacecoordinatorkit`](.agents/skills/integrate-surfacecoordinatorkit/SKILL.md)
  — the integration/migration workflow for coding agents, including the
  entry-point split audit and legacy cooldown seeding.
- **Adoption lint**: `surface-coordinator-kit-lint` in
  [product-playbook](https://github.com/Jewel591/product-playbook) `scripts/`
  — Linux-compatible structural check that App Store apps depend on the Kit
  with a compatible version range and actually construct a coordinator and
  arbitrate in production app-target code.

## Engineering

- Swift 6 strict concurrency; `SurfaceCoordinator` and the stores are
  `@MainActor`.
- Public API supports iOS 17, macOS 14, and visionOS 1.
- Zero dependencies, and by invariant it stays that way: no UI framework, no
  RevenueCat/StoreKit, no host sheet coordinator, not even AppContextKit.
- Every rule change requires focused unit tests, including exact time
  boundaries (`Tests/SurfaceCoordinatorKitTests`).
