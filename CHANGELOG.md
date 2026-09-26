# Changelog

## 1.0.0 - 2026-09-26

### Breaking

- `SurfaceCoordinator` is now the canonical process runtime (`SurfaceCoordinator.shared`, `@Observable`). Hosts register producers and submit candidates instead of calling `arbitrate` and `recordOutcome`, which are no longer public.
- `SurfaceRequest` is replaced by `SurfaceProducer`. Order inside a tier comes from the new `SurfacePurpose` and then the producer id, never from host listing order.
- `SurfaceProducer` refuses the `.passive` tier: persistent passive UI does not compete for the permit.

### Added

- Producer registry (idempotent), pending candidates with a bounded wait, `submit` / `withdraw`, a single presentation permit with generations, and counted occupancy owners.
- `SurfaceCoordinatorKitUI` product: the `.surfaceHost` SwiftUI adapter gates on the window's scene, owns the sheet / cover, records `.presented` only after the content reached the window, withdraws and retries presentations that did not land, and releases the permit after dismissal or window close.
- `performUnobservable` for StoreKit-style requests, recorded as `.attempted` without cooldown or budget.
- `SurfaceEvent` lifecycle events, `hasActivity`, `isPresenting`, and standard producer ids for Kit-owned surfaces.

## 0.2.0 - 2026-08-19

### Added

- Add `clearAllSignals()` for process-wide teardown such as sign-out or replacing every scene root.

### Fixed

- Preserve the newest legacy presentation timestamp independently for both surface and category cooldown history.
- Pin cooldown, succession, and expiring-signal behavior to their exact time boundaries in tests.

## 0.1.0 - 2026-08-16

- Initial public release of app-initiated surface arbitration.
