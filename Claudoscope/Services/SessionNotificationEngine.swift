import Foundation

/// Pure logic for session lifecycle notifications: parsing hook spool payloads,
/// deciding what counts as "waiting on you", and deciding which sessions have
/// "completed" (ran a while, then went quiet). No I/O and no posting, so it is
/// unit-testable under `swift test`. Mirrors `CostAlertEngine`.
enum SessionNotificationEngine {

    /// Decoded Claude Code Notification-hook payload, as written to the spool by
    /// `claudoscope-notify.sh`.
    struct SpoolEvent: Sendable, Equatable {
        let sessionId: String
        let cwd: String?
        let transcriptPath: String?
        let notificationType: String?
        let message: String?
    }

    /// Per-session activity tracked for the "completed" timer.
    struct ActivitySnapshot: Sendable, Equatable {
        var spanSeconds: Double
        var lastActivityWall: Date
        var projectId: String
        var firedCompleted: Bool
        var waitingSince: Date?
    }

    private static let idlePhrase = "waiting for your input"

    /// Parse a spool file's raw JSON. Tolerates missing keys; returns nil only
    /// when the payload is not a JSON object or carries no `session_id`.
    static func parseSpoolPayload(_ data: Data) -> SpoolEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionId = obj["session_id"] as? String, !sessionId.isEmpty else {
            return nil
        }
        return SpoolEvent(
            sessionId: sessionId,
            cwd: obj["cwd"] as? String,
            transcriptPath: obj["transcript_path"] as? String,
            notificationType: obj["notification_type"] as? String,
            message: obj["message"] as? String
        )
    }

    /// A Notification is "waiting on you" when it is a real block (permission
    /// prompt, plan approval, MCP elicitation) but NOT the passive idle prompt
    /// that re-fires ~every 60s. Mirrors `session-notify.sh`: drop when the type
    /// is idle, or (type absent) the message is the idle phrase.
    static func isWaiting(notificationType: String?, message: String?) -> Bool {
        if let type = notificationType, !type.isEmpty {
            return !type.contains("idle")
        }
        if let message, message.localizedCaseInsensitiveContains(idlePhrase) {
            return false
        }
        return true
    }

    /// Session ids that should fire a "completed" notification now: ran at least
    /// `activeMinutes`, silent for at least `quietSeconds`, not currently waiting,
    /// and not already fired. Per-project mute and quiet hours are applied by the
    /// caller (they depend on config).
    static func completedSessionsToFire(
        _ activity: [String: ActivitySnapshot],
        now: Date,
        activeMinutes: Int = 10,
        quietSeconds: Int = 180
    ) -> [String] {
        let minSpan = Double(activeMinutes) * 60
        let minQuiet = Double(quietSeconds)
        return activity.compactMap { id, snap in
            guard !snap.firedCompleted,
                  snap.waitingSince == nil,
                  snap.spanSeconds >= minSpan,
                  now.timeIntervalSince(snap.lastActivityWall) >= minQuiet
            else { return nil }
            return id
        }
    }
}
