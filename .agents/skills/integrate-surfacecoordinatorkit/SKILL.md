---
name: integrate-surfacecoordinatorkit
description: Integrate, migrate, review, or troubleshoot an Apple app that uses the SurfaceCoordinatorKit Swift package. Use when adding SurfaceCoordinatorKit to a Swift/SwiftUI app, unifying decisions about which app-initiated surface shows next (forced update, launch paywall, promotion, announcement, review prompt, What's New), replacing hand-written cross-surface gate flags or "wait until the paywall check finished" booleans, auditing that user-initiated presentations are NOT arbitrated, or migrating legacy last-shown dates so existing users keep their cooldown position.
---

# Integrate SurfaceCoordinatorKit

Use SurfaceCoordinatorKit as the app's single arbiter for **app-initiated**
surfaces: every business feature produces a `SurfaceRequest` candidate, one
`SurfaceCoordinator` with one `SurfacePolicySet` decides which candidate (if
any) presents now, and the host reports back what actually happened. The Kit
decides *why and when*; the app keeps *what it looks like* and *in what order
sheets physically appear*.

## Read the local contract

Read the package `README.md` and the current public declarations under
`Sources/SurfaceCoordinatorKit/` before changing an app. Do not reconstruct
API names from memory. The doc comments on `SurfaceCoordinator` are the
authoritative statement of the scope norm and of which outcome mutates state.

Also read and obey the target repository's `AGENTS.md` / `CLAUDE.md` or
equivalent instructions.

## The scope norm you must enforce

- **App-initiated goes through the coordinator; user-initiated never does.**
  A presentation the user explicitly asked for (button tap, deep link) is
  presented directly — arbitrating it, and possibly answering "not now", is a
  bug you would be introducing.
- A page with both identities (paywall from settings vs. auto-shown at launch)
  keeps one page and **splits the entry points**; only the app-initiated entry
  is arbitrated.
- User-initiated activity is still reported as context signals
  (`registerSignal`/`clearSignal`) so app-initiated surfaces defer while the
  user is busy.

## Follow this workflow

1. Inventory the app's surfaces. Classify every sheet/fullScreenCover/banner
   trigger as **app-initiated** (update prompts, launch paywall, promotions,
   announcements, What's New, review prompts, recovery hints) or
   **user-initiated** (deep links, button taps). List existing cross-surface
   gate hacks: booleans like "review waits until the paywall check completed",
   implicit enqueue ordering at launch, ad-hoc `DispatchQueue.asyncAfter`
   delays between popups. These gates are what the integration deletes.
2. Add the package dependency (`https://github.com/Jewel591/SurfaceCoordinatorKit`,
   up-to-next-major from the latest release) to the app target only.
3. Define the app's `SurfaceCategory` vocabulary in one file, and build one
   `SurfacePolicySet` in one place. Transcribe each deleted gate hack into the
   matching primitive: pairwise "not right after" → `SurfaceSuccessionRule`;
   "at most one popup per launch" → `sessionInterruptionBudget`; "24h between
   paywalls" → `surfaceCooldowns`; "not during onboarding / while a sheet is
   up / right after a failed purchase" → `SurfaceSuppressionRule` + signals.
   Do not invent rules the app does not currently need.
4. Construct one `SurfaceCoordinator` at app composition level. Call
   `beginSession()` at launch and wherever the app defines "a new foreground
   session". If a single-surface policy Kit is already in place (e.g.
   InAppPromotionKit eligibility/cooldown), keep it as the *per-surface*
   policy producing or withholding that one candidate; the coordinator does
   the *cross-surface* round.
5. Wire the round: gather candidates (tier order: `.blocking` for can't-continue
   surfaces, `.interruptive` for modals, `.passive` for banners; within a tier
   list in precedence order), call `arbitrate`, hand the winner to the app's
   existing presentation layer (sheet queue/coordinator stays — it is the
   renderer), then call `recordOutcome`. Report `.presented` only when the
   surface actually reached the screen; `.skipped`/`.failed` keep it eligible.
6. Plan legacy cooldown migration **before** the first arbitration on an
   existing install: seed prior "last shown" dates via
   `UserDefaultsSurfaceStateStore.seedPresentation(...)` one time, otherwise
   every existing user is treated as never-shown and gets re-prompted.
7. Register signals from the places the policy references: user-initiated
   sheet appears/disappears, system permission prompt around, critical flow
   entry/exit, domain events like a failed purchase (use `expiresAfter` for
   time-boxed ones so a missed clear cannot suppress forever).
8. Assemble launch candidates so a remote eligibility check cannot stall a
   locally ready higher-priority surface. See **Host assembly pitfalls**.
9. Delete the replaced gate flags and ordering hacks in the same change. Two
   parallel arbitration mechanisms are worse than either alone.
10. Build and run the smallest relevant tests. Test host policy through an
    injected `InMemorySurfaceStateStore` and a fixed `now` closure; never test
    against `.standard` UserDefaults or real time.
11. Verify against the lint: `surface-coordinator-kit-lint` (product-playbook)
    requires the SPM dependency with a compatible version range, a production
    `import SurfaceCoordinatorKit`, a module-qualified
    `SurfaceCoordinatorKit.SurfaceCoordinator(...)` construction, and an
    `.arbitrate(...)` call in the app target. Passing the lint is necessary,
    not sufficient — the entry-point split and gate deletion above are what it
    cannot check.

## Preserve these boundaries

- The coordinator answers "which app-initiated surface now"; it never renders
  and never serializes actual presentation.
- Tiers are the only priority vocabulary; do not smuggle numeric priorities
  into ids or categories.
- Signals are opaque keys; their meaning lives in the host policy, never in
  the Kit.
- `arbitrate` is side-effect free; only `recordOutcome(.presented, ...)`
  stamps cooldowns and budget.
- Storage keys under the `SurfaceCoordinatorKit.` prefix belong to the Kit;
  host code never writes them outside the one-time seeding call.

## Host assembly pitfalls

These are host mistakes. The Kit cannot prevent them; every integration that
skipped them paid a Codex medium.

- **Do not await a remote eligibility check when a local higher-priority
  candidate is already known.** App Store lookup and RevenueCat promotion
  queries take seconds. If What's New (or any other local candidate) is
  already ready, arbitrate now. Kick the remote check off in the background
  and re-run the round after dismiss. Awaiting the lookup to "keep update
  first" loses the whole round when the user taps into a detail during the
  wait — and a process-once lookup cannot retry. `hasCompletedCheckThisLaunch`
  only blocks *lower-priority* surfaces from sneaking in while lookup is
  still in flight; it is not a license to stall every launch surface.
- **Signals are process-global; windows are not.** Each scene contributes a
  snapshot; OR-aggregate before `registerSignal` / `clearSignal`. An idle
  window must not clear another window's settings signal. `beginSession()`
  starts a new interruption budget — do not call it when any scene still
  shows an app-initiated surface, and do not copy a process-global
  "review pending" flag into per-scene occupancy.
- **`clearAllSignals()` is process-wide teardown, not a single-scene
  swapRoot.** Signals are process-global. Call it for sign-out, the last
  window going away, or replacing every scene's root — dying views often
  have `view.window == nil`, so `viewDidDisappear` cannot be the only
  clear. A single-scene UIKit root swap must not call `clearAllSignals()`:
  update that scene's snapshot and re-OR-aggregate. There is no public API
  to read expiries back, so a bulk clear cannot reconstruct purchase-failed
  or other domain signals. SwiftUI hosts that never replace the root can
  skip this.
- **Overlapping user sheets need a host-side count.** Kit signals are
  boolean. `enter` increments, the last `exit` calls `clearSignal`. A
  bool set/clear on each sheet will drop the signal while another sheet
  is still up.
- **Async rounds need a generation token.** If `arbitrate` waits on lookup,
  a newer round may have already decided. Apply the await result only when
  the token still matches and no winner is on screen.

## Review the result

Before declaring the integration complete: confirm no user-initiated
presentation path routes through `arbitrate`; confirm every app-initiated
surface produces a candidate instead of presenting itself; confirm the old
gate flags/ordering hacks are deleted; confirm an existing user upgrading
keeps their cooldown position (state seeded, not reset); and log or spot-check
`arbitration.summary` once to verify "why didn't X show" is answerable. State
explicitly which legacy gates were deleted, which legacy last-shown keys were
seeded, and which surfaces were intentionally left outside the coordinator
(and why they are user-initiated).

## Host test boundary

- Test the host's candidate/policy table, signal mapping, user-sheet occupancy count, generation-token chokepoint, and every real legacy cooldown key seeded during migration.
- Arbitration ordering, cooldown/budget arithmetic, stale-round handling primitives, store mechanics, and candidate eligibility rules supplied by SurfaceCoordinatorKit belong to package tests; do not reproduce the engine matrix in every app.
- Cross-Kit orchestration tests should assert only the host decision — for example, which candidate wins for a set of app facts — without replaying ReviewKit/AppUpdateKit/WhatsNewKit internals.
- Do not inspect `project.pbxproj`, imports, constructor strings or deleted flags in XCTest; structural assembly belongs to the playbook lint. Use an in-memory store, fixed clock and public APIs. If two apps copy the same policy helper, evaluate whether that policy is truly portfolio-wide and should become a Kit semantic instead.
