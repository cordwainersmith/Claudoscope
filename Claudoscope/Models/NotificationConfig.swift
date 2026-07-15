import Foundation

/// Configuration for session lifecycle notifications (waiting / completed).
/// Persisted as JSON in UserDefaults, mirroring `CostAlertConfig`.
struct NotificationConfig: Codable, Sendable, Equatable {
    var masterEnabled: Bool
    var soundEnabled: Bool
    var quietHoursEnabled: Bool
    /// Minutes since local midnight. When start > end the window wraps midnight.
    var quietHoursStartMinutes: Int
    var quietHoursEndMinutes: Int
    /// Project ids (encoded projects-subdir names) muted from all notifications.
    var mutedProjectIds: Set<String>
    /// Per-event delivery switches: a real block (permission/plan/MCP prompt)
    /// from the Notification hook, and "your turn" from the Stop hook.
    var notifyOnBlocks: Bool
    var notifyOnYourTurn: Bool

    static let `default` = NotificationConfig(
        masterEnabled: false,
        soundEnabled: true,
        quietHoursEnabled: false,
        quietHoursStartMinutes: 22 * 60,   // 22:00
        quietHoursEndMinutes: 7 * 60,      // 07:00
        mutedProjectIds: [],
        notifyOnBlocks: true,
        notifyOnYourTurn: true
    )

    /// True when `now` (local time) falls inside the quiet-hours window. A window
    /// whose start is after its end (e.g. 22:00–07:00) wraps past midnight.
    func isInQuietHours(_ now: Date, calendar: Calendar = .current) -> Bool {
        guard quietHoursEnabled, quietHoursStartMinutes != quietHoursEndMinutes else { return false }
        let comps = calendar.dateComponents([.hour, .minute], from: now)
        let minutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        if quietHoursStartMinutes < quietHoursEndMinutes {
            return minutes >= quietHoursStartMinutes && minutes < quietHoursEndMinutes
        } else {
            return minutes >= quietHoursStartMinutes || minutes < quietHoursEndMinutes
        }
    }
}

// Custom decode so adding the per-event fields never invalidates a saved config:
// missing keys default to true (all events on) instead of throwing, which would
// otherwise reset every other setting back to `.default`.
extension NotificationConfig {
    private enum CodingKeys: String, CodingKey {
        case masterEnabled, soundEnabled, quietHoursEnabled
        case quietHoursStartMinutes, quietHoursEndMinutes, mutedProjectIds
        case notifyOnBlocks, notifyOnYourTurn
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        masterEnabled = try c.decode(Bool.self, forKey: .masterEnabled)
        soundEnabled = try c.decode(Bool.self, forKey: .soundEnabled)
        quietHoursEnabled = try c.decode(Bool.self, forKey: .quietHoursEnabled)
        quietHoursStartMinutes = try c.decode(Int.self, forKey: .quietHoursStartMinutes)
        quietHoursEndMinutes = try c.decode(Int.self, forKey: .quietHoursEndMinutes)
        mutedProjectIds = try c.decode(Set<String>.self, forKey: .mutedProjectIds)
        notifyOnBlocks = try c.decodeIfPresent(Bool.self, forKey: .notifyOnBlocks) ?? true
        notifyOnYourTurn = try c.decodeIfPresent(Bool.self, forKey: .notifyOnYourTurn) ?? true
    }
}
