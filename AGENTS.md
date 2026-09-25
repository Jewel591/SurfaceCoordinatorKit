# SurfaceCoordinatorKit

Public Swift package that decides which app-initiated surface (updates,
paywalls, announcements, What's New, review requests) may reach the screen,
across Apple-platform apps.

## Product boundary

- `SurfaceCoordinatorKit` is the canonical process runtime
  (`SurfaceCoordinator.shared`): producer registry, pending candidates, one
  presentation permit with generations, counted occupancy, rule evaluation
  (tier / purpose / id order, cooldowns, session budget, succession bans,
  signal suppression), outcome recording and cooldown persistence. It stays
  pure Foundation.
- `SurfaceCoordinatorKitUI` is the SwiftUI presentation adapter: one host per
  window, scene gating, sheet / cover ownership, landing confirmation,
  dismissal reporting. The scene gate lives here, never in the core. macOS
  maps covers to sheets.
- Host apps own content views, the policy parameters (`SurfacePolicySet`),
  and blocking facts the Kit cannot derive, reported as occupancy.
- **Scope norm**: only app-initiated surfaces become producers. User-initiated
  presentations stay in the host and report occupancy. Persistent passive UI
  never registers; `SurfaceProducer` refuses `.passive`.
- Ordering is tier, then `SurfacePurpose`, then producer id. Do not add
  numeric priorities, and never let registration, submission or host array
  order influence the winner.
- Signals are opaque keys; their meaning lives in host policy.
  `clearAllSignals()` is for process-wide teardown and does not reset the
  session. Overlapping owners use occupancy, not signals.
- Unobservable system UI (StoreKit review) goes through
  `performUnobservable`, never the adapter, and is recorded as `.attempted`:
  no cooldown, no budget, no further interruptive producer this session.

## Engineering

- Swift 6 strict concurrency. iOS 17, macOS 14, visionOS 1.
- Zero third-party dependencies by invariant: no RevenueCat / StoreKit, no
  host sheet coordinator, no AppContextKit. Cooldown persistence uses the
  Kit's own `SurfaceCoordinatorKit.` UserDefaults prefix.
- Only a confirmed landing (`confirmPresented`) stamps cooldowns and budget.
  Every permit callback checks the generation, so a stale attempt never acts
  on a later one. Every rejection carries a machine-readable reason.
- The adapter contract (`requestPermit`, `confirmPresented`,
  `reportNotLanded`, `completeDismissal`, `abandon`) is `package` access;
  hosts cannot call it.
- Every rule or runtime change requires focused package tests, including
  exact time boundaries. Tests inject `InMemorySurfaceStateStore` and a fixed
  `now` closure; never test against `.standard` UserDefaults or real time.
- ⚠️ Known pitfall, do not regress: `signals` is `[String: Date?]`; writing a
  nil expiry must go through `updateValue`, because subscript assignment with
  a nil `Date?` removes the key instead of storing "no expiry".

## Companion tooling (keep in sync with API changes)

- Agent skill `.agents/skills/integrate-surfacecoordinatorkit/SKILL.md` —
  update whenever public API or the scope norm changes.
- Adoption lint `surface-coordinator-kit-lint` in product-playbook `scripts/`
  checks production app-target code for `import SurfaceCoordinatorKitUI`, a
  `.surfaceHost` call and a `SurfaceProducer(...)` registration, and rejects
  constructing a second `SurfaceCoordinator(...)`. Renaming those symbols
  requires a same-day playbook PR bumping the lint.
