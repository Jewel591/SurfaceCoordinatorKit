# Changelog

## 0.2.0 - 2026-08-19

### Added

- Add `clearAllSignals()` for process-wide teardown such as sign-out or replacing every scene root.

### Fixed

- Preserve the newest legacy presentation timestamp independently for both surface and category cooldown history.
- Pin cooldown, succession, and expiring-signal behavior to their exact time boundaries in tests.

## 0.1.0 - 2026-08-16

- Initial public release of app-initiated surface arbitration.
