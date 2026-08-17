# SurfaceCoordinatorKit

Public Swift package that arbitrates app-initiated surfaces (updates, paywalls,
promotions, announcements, review prompts) across Apple-platform apps.

## Product boundary

- The package owns the arbitration primitives — tier ordering, per-surface and
  per-category cooldowns, session interruption budget, succession bans,
  signal-driven suppression — plus verdict reasons, outcome recording, and
  cooldown persistence.
- Host apps own the rule parameters (`SurfacePolicySet`), all rendering, and
  presentation serialization (an app's sheet queue is a renderer concern and
  stays in the app).
- **Scope norm**: only app-initiated surfaces are arbitrated. User-initiated
  presentations (button tap, deep link) must never be routed through the
  coordinator — present them directly and, where relevant, report them as
  context signals. A page reused by both identities splits its entry points.
- Tiers are a fixed semantic vocabulary (`blocking` / `interruptive` /
  `passive`); do not add numeric priorities. Within a tier, host listing order
  is precedence.
- Signals are opaque keys. Do not add semantic knowledge of specific signals
  (e.g. "purchase failed") to the Kit; that meaning lives in host policy.
- `clearAllSignals()` is the bulk clear for in-process UI teardown (UIKit
  root replacement). It must not reset the session budget; that stays
  `beginSession()`. Do not add occupancy/refcount to signals — overlapping
  sheets count in the host.

## Engineering

- Swift 6 strict concurrency. Public API supports iOS 17, macOS 14, visionOS 1.
- Zero dependencies by invariant: no UI framework, no RevenueCat/StoreKit, no
  host sheet coordinator, no AppContextKit. Cooldown persistence is the Kit's
  own (`SurfaceCoordinatorKit.` UserDefaults prefix), not AppContextKit's
  `Throttle` — sharing state stores across Kits couples their release cycles.
- `arbitrate` must stay side-effect free; only `recordOutcome(.presented, ...)`
  mutates state. Every rejection carries a machine-readable reason; never
  return a bare "no".
- Every rule change requires focused unit tests including exact time
  boundaries. Tests inject `InMemorySurfaceStateStore` and a fixed `now`
  closure; never test against `.standard` UserDefaults or real time.
- ⚠️ Known pitfall, do not regress: `signals` is `[String: Date?]`; writing a
  nil expiry must go through `updateValue`, because subscript assignment with
  a nil `Date?` removes the key instead of storing "no expiry".

## Companion tooling (keep in sync with API changes)

- Agent skill `.agents/skills/integrate-surfacecoordinatorkit/SKILL.md` —
  update whenever public API or the scope norm changes.
- Adoption lint `surface-coordinator-kit-lint` in product-playbook `scripts/`
  scans for `import SurfaceCoordinatorKit`,
  `SurfaceCoordinatorKit.SurfaceCoordinator(...)` construction, and
  `.arbitrate(...)` use in production app-target code. Renaming those symbols
  requires a same-day playbook PR bumping the lint.
