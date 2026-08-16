import Foundation

/// Persistence boundary for presentation history. Cooldowns and succession
/// rules read it; `SurfaceCoordinator.recordOutcome(.presented)` writes it.
@MainActor
public protocol SurfaceStateStoring: AnyObject {
    func lastPresentation(cooldownKey: String) -> Date?
    func lastPresentation(category: SurfaceCategory) -> Date?
    func recordPresentation(cooldownKey: String, category: SurfaceCategory, at date: Date)

    /// Forgets all history (testing / debug reset).
    func reset()
}

/// Production store persisting across launches in `UserDefaults`.
///
/// Storage keys live under the `SurfaceCoordinatorKit.` prefix and belong to
/// the Kit — never write them directly from host code, except for a one-time
/// legacy migration via `seedPresentation(...)`.
@MainActor
public final class UserDefaultsSurfaceStateStore: SurfaceStateStoring {
    private let userDefaults: UserDefaults
    private static let prefix = "SurfaceCoordinatorKit."

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    private func surfaceKey(_ cooldownKey: String) -> String {
        Self.prefix + "surface." + cooldownKey
    }

    private func categoryKey(_ category: SurfaceCategory) -> String {
        Self.prefix + "category." + category.rawValue
    }

    public func lastPresentation(cooldownKey: String) -> Date? {
        userDefaults.object(forKey: surfaceKey(cooldownKey)) as? Date
    }

    public func lastPresentation(category: SurfaceCategory) -> Date? {
        userDefaults.object(forKey: categoryKey(category)) as? Date
    }

    public func recordPresentation(
        cooldownKey: String, category: SurfaceCategory, at date: Date
    ) {
        userDefaults.set(date, forKey: surfaceKey(cooldownKey))
        userDefaults.set(date, forKey: categoryKey(category))
    }

    /// One-time migration entry point: seed history from a legacy
    /// "last shown" date the app tracked before adopting the Kit, so existing
    /// users keep their cooldown position instead of being treated as
    /// never-shown.
    ///
    /// Surface and category history advance independently, and each only when
    /// the stored date is missing or older — seeding several legacy surfaces
    /// of the same category must end at the newest date regardless of the
    /// order the host enumerates them in.
    public func seedPresentation(
        cooldownKey: String, category: SurfaceCategory, at date: Date
    ) {
        if lastPresentation(cooldownKey: cooldownKey).map({ $0 < date }) ?? true {
            userDefaults.set(date, forKey: surfaceKey(cooldownKey))
        }
        if lastPresentation(category: category).map({ $0 < date }) ?? true {
            userDefaults.set(date, forKey: categoryKey(category))
        }
    }

    public func reset() {
        for key in userDefaults.dictionaryRepresentation().keys
        where key.hasPrefix(Self.prefix) {
            userDefaults.removeObject(forKey: key)
        }
    }
}

/// Ephemeral store for tests and previews.
@MainActor
public final class InMemorySurfaceStateStore: SurfaceStateStoring {
    private var surfaceDates: [String: Date] = [:]
    private var categoryDates: [SurfaceCategory: Date] = [:]

    public init() {}

    public func lastPresentation(cooldownKey: String) -> Date? {
        surfaceDates[cooldownKey]
    }

    public func lastPresentation(category: SurfaceCategory) -> Date? {
        categoryDates[category]
    }

    public func recordPresentation(
        cooldownKey: String, category: SurfaceCategory, at date: Date
    ) {
        surfaceDates[cooldownKey] = date
        categoryDates[category] = date
    }

    public func reset() {
        surfaceDates.removeAll()
        categoryDates.removeAll()
    }
}
