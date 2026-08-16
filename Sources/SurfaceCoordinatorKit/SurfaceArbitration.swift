import Foundation

/// Why one candidate was not selected this round.
///
/// Every rejection carries a machine-readable reason so "why didn't X show"
/// is always answerable from a log line instead of a debugging session.
public enum SurfaceRejectionReason: Sendable, Equatable, CustomStringConvertible {
    /// This surface's own cooldown has not elapsed yet.
    case surfaceCooldownActive(remaining: TimeInterval)

    /// Another surface of the same category was presented too recently.
    case categoryCooldownActive(remaining: TimeInterval)

    /// The foreground session already used up its interruption budget.
    case sessionBudgetExhausted

    /// An active context signal defers this request.
    case suppressedBySignal(key: String)

    /// A succession rule blocks this category right after another one.
    case successionBlocked(previous: SurfaceCategory, remaining: TimeInterval)

    /// The candidate was eligible but another candidate won the round.
    case lostToHigherPriority(winnerID: String)

    public var description: String {
        switch self {
        case .surfaceCooldownActive(let remaining):
            "surface cooldown active (\(Int(remaining))s remaining)"
        case .categoryCooldownActive(let remaining):
            "category cooldown active (\(Int(remaining))s remaining)"
        case .sessionBudgetExhausted:
            "session interruption budget exhausted"
        case .suppressedBySignal(let key):
            "suppressed by signal '\(key)'"
        case .successionBlocked(let previous, let remaining):
            "blocked after '\(previous)' (\(Int(remaining))s remaining)"
        case .lostToHigherPriority(let winnerID):
            "lost to '\(winnerID)'"
        }
    }
}

/// The decision for one candidate in one arbitration round.
public struct SurfaceVerdict: Sendable, Equatable {
    public enum Resolution: Sendable, Equatable {
        case selected
        case rejected(SurfaceRejectionReason)
    }

    public let request: SurfaceRequest
    public let resolution: Resolution
}

/// The full result of one arbitration round: at most one winner, plus a
/// verdict with reason for every candidate. Log `summary` whenever the answer
/// to "why did/didn't it show" might be asked later — that is, always.
public struct SurfaceArbitration: Sendable, Equatable {
    /// The single request the host renderer should present now, if any.
    public let winner: SurfaceRequest?

    /// One verdict per candidate, in evaluation order (tier-descending,
    /// then the order the host listed them in).
    public let verdicts: [SurfaceVerdict]

    /// One log-friendly line describing the whole round.
    public var summary: String {
        let parts = verdicts.map { verdict in
            switch verdict.resolution {
            case .selected:
                "\(verdict.request.id)=selected"
            case .rejected(let reason):
                "\(verdict.request.id)=rejected(\(reason))"
            }
        }
        return "winner=\(winner?.id ?? "none") [\(parts.joined(separator: "; "))]"
    }
}
