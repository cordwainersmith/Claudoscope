import Foundation

/// Pure logic for session lifecycle notifications: parsing hook spool payloads
/// and classifying the passive idle prompt. No I/O and no posting, so it is
/// unit-testable under `swift test`. Mirrors `CostAlertEngine`.
enum SessionNotificationEngine {

    /// Decoded Claude Code hook payload, as written to the spool by
    /// `claudoscope-notify.sh`. The same bridge script forwards both the
    /// `Notification` and `Stop` hooks, so `hookEventName` distinguishes them.
    struct SpoolEvent: Sendable, Equatable {
        let sessionId: String
        let cwd: String?
        let transcriptPath: String?
        let notificationType: String?
        let message: String?
        let hookEventName: String?
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
            message: obj["message"] as? String,
            hookEventName: obj["hook_event_name"] as? String
        )
    }

    /// True when a Notification is the passive idle prompt ("waiting for your
    /// input"), which re-fires ~every 60s, as opposed to a real block (permission
    /// prompt, plan approval, MCP elicitation). Idle is dropped; blocks fire.
    /// Mirrors `session-notify.sh`'s idle detection.
    static func isIdlePrompt(notificationType: String?, message: String?) -> Bool {
        if let type = notificationType, !type.isEmpty {
            return type.contains("idle")
        }
        if let message, message.localizedCaseInsensitiveContains(idlePhrase) {
            return true
        }
        return false
    }
}
