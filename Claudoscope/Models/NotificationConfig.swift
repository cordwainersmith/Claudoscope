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

    static let `default` = NotificationConfig(
        masterEnabled: false,
        soundEnabled: true,
        quietHoursEnabled: false,
        quietHoursStartMinutes: 22 * 60,   // 22:00
        quietHoursEndMinutes: 7 * 60,      // 07:00
        mutedProjectIds: []
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
