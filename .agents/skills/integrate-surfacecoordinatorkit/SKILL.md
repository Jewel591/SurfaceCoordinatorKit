---
name: integrate-surfacecoordinatorkit
description: Integrate, migrate, review, or troubleshoot an Apple app that uses the SurfaceCoordinatorKit Swift package. Use when adding SurfaceCoordinatorKit to a Swift/SwiftUI app, migrating from the 0.x arbitrate/recordOutcome API to the 1.x producer runtime and .surfaceHost adapter, unifying which app-initiated surface shows next (update prompt, launch paywall, announcement, What's New, review request), replacing hand-written cross-surface gate flags or app-level sheet bindings for self-initiated surfaces, auditing that user-initiated presentations are NOT producers, or migrating legacy last-shown dates so existing users keep their cooldown position.
---

# Integrate SurfaceCoordinatorKit

SurfaceCoordinatorKit 1.x is one process runtime plus one SwiftUI adapter.
Every app-initiated surface is a **producer** registered on
`SurfaceCoordinator.shared`; each window root carries `.surfaceHost`, which
presents the winner, confirms it reached the window and reports dismissal.
The host keeps only content views, the policy parameters and blocking facts.

## Read the local contract

Read the package `README.md` and the public declarations under
`Sources/SurfaceCoordinatorKit/` and `Sources/SurfaceCoordinatorKitUI/` before
changing an app. Do not reconstruct API names from memory. Also read and obey
the target repository's `AGENTS.md` or equivalent instructions.

## The scope norm you must enforce

- **App-initiated surfaces are producers; user-initiated never are.** A
  presentation the user asked for (button tap, deep link) stays in the app's
  own presentation layer and is reported with `setOccupied(_:by:)`.
- A page with both identities (paywall from settings vs. auto-shown at launch)
  keeps one page and **splits the entry points**; only the app-initiated entry
  is a producer.
- Badges and banners never register. `.passive` producers trap.
- StoreKit review goes through `performUnobservable`, never through the host
  and never as `.presented`.

## Follow this workflow

1. **Inventory.** Classify every sheet / fullScreenCover / banner trigger as
   app-initiated or user-initiated. List what the migration deletes: app-level
   bindings for self-initiated sheets and covers, hand-written `.presented`
   bookkeeping, candidate builders, gate booleans ("review waits for the
   paywall check"), fixed priority tables, generation helpers, delays between
   popups, and "a surface is showing" flags.
2. **Dependency.** Add `https://github.com/Jewel591/SurfaceCoordinatorKit`
   (up-to-next-major from the latest release) to the app target, linking both
   `SurfaceCoordinatorKit` and `SurfaceCoordinatorKitUI`. watchOS targets do
   not link the adapter.
3. **Policy.** Build one `SurfacePolicySet` in one place and call
   `SurfaceCoordinator.shared.configure(policies:)` at launch, followed by
   `beginSession()`. Transcribe each deleted gate into a primitive: "not right
   after" → `SurfaceSuccessionRule`; "at most N popups per launch" →
   `sessionInterruptionBudget`; "24h between paywalls" → `surfaceCooldowns`;
   time-boxed domain vetoes → `SurfaceSuppressionRule` + signals. Do not
   invent rules the app does not currently need; keep the budget that
   reproduces today's behavior.
4. **Producers.** Register each app-initiated surface once with a stable id,
   category, tier, purpose and style. Use the standard ids
   (`.appUpdate`, `.whatsNew`, `.launchPromotion`, `.review`) for those
   surfaces so history carries over when their Kit takes ownership. Move
   "marked as shown / seen" bookkeeping into `onPresented` / `onDismissed`.
5. **Candidates.** Local facts `submit` directly. Remote checks call
   `markPending` first, then `submit` or `withdraw`. Hold the payload a
   content view needs (What's New content, a detection result) in host state
   keyed by producer id; the runtime only carries ids.
6. **Host.** Put `.surfaceHost { id in … }` on the root content of every
   window and delete the app-level bindings for self-initiated surfaces. The
   content closure maps a producer id to its view; it must not decide
   eligibility.
7. **Occupancy.** Report every blocking fact the Kit cannot see: onboarding,
   lock / biometric screens, sign-in or account merge flows, user-initiated
   sheets. Owners are strings; use distinct owners per scene when windows are
   independent. Release in the same place the fact ends.
8. **User-initiated presentation layer.** Keep the app's own sheet queue for
   user-initiated pages. It must wait while `isPresenting` is true and report
   occupancy while it shows or holds a queued page.
9. **Legacy cooldowns.** Before the first grant on an existing install, seed
   prior "last shown" dates once through
   `UserDefaultsSurfaceStateStore.seedPresentation(...)`.
10. **Diagnostics.** Route `eventHandler` to the app's logging. Forward
    `.notLanded(…, isFinal: true, …)` to the error tracker: it is the signal
    that a surface never reached users.
11. **Delete** the replaced flags, bindings and ordering hacks in the same
    change. Two parallel arbitration paths are worse than either alone.
12. **Verify** with `surface-coordinator-kit-lint` (product-playbook). Passing
    the lint is necessary, not sufficient — the entry-point split, occupancy
    coverage and deletions above are what it cannot check.

## Preserve these boundaries

- One runtime per process: production code uses `SurfaceCoordinator.shared`;
  the initializer is a test seam.
- Order comes from tier, purpose and id. Do not smuggle priorities into ids.
- Hosts never call the adapter contract (it is `package` access) and never
  record presentations themselves.
- Signals are opaque keys; their meaning lives in the host policy.
- Storage keys under the `SurfaceCoordinatorKit.` prefix belong to the Kit.

## Host assembly pitfalls

- **Do not await a remote check before submitting local candidates.** Mark
  the remote producer pending and submit local ones immediately; the bounded
  pending wait keeps precedence without stalling launch.
- **Do not bind a self-initiated surface outside `.surfaceHost`.** A binding
  set while the app runs in the background never reaches the screen but
  still fires `onAppear`; that is the failure the adapter exists to prevent.
- **Occupancy must end.** Release it where the fact ends, including
  cancellation and error paths; an owner that is never released blocks every
  producer for the process.
- **`beginSession()` lifts the post-review hold and resets the budget.** Call
  it only where the app defines a new foreground session.
- **`clearAllSignals()` is process-wide teardown.** A single-scene root swap
  must not call it.

## Review the result

Confirm: no user-initiated path is a producer; every app-initiated surface is
a registered producer rendered only by `.surfaceHost`; every blocking fact is
occupancy with a matching release; old flags, bindings and priority tables are
deleted; review uses `performUnobservable`; legacy cooldowns were seeded.
State which legacy gates were deleted and which surfaces were intentionally
left outside the runtime and why.

## Host test boundary

- Test the host's own table: which facts submit or withdraw which producer,
  the occupancy owners and their release, the payload each content view gets,
  and every legacy cooldown key seeded during migration.
- Ordering, permits, generations, landing retries, occupancy counting,
  outcome state and store mechanics belong to package tests; do not reproduce
  them in apps.
- Do not inspect `project.pbxproj`, imports or constructor strings in XCTest;
  structural assembly belongs to the playbook lint. Use an in-memory store and
  a fixed clock through the public initializer.
