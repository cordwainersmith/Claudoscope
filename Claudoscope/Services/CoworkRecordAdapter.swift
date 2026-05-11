import Foundation

/// Reshapes a single Cowork audit.jsonl line into the field shape SessionParser
/// expects for Claude Code JSONL. Two transforms:
///   1. `_audit_timestamp` → `timestamp`
///   2. Strip top-level `session_id` (it's the inner Claude Code subprocess ID,
///      and SessionParser's parent-skip branch would drop billable records if
///      it ever collided with a real session ID).
///
/// Returns nil for blank lines or anything that can't be parsed as JSON. The
/// caller is expected to skip nils and continue.
enum CoworkRecordAdapter {
    static func adaptLine(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8),
              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if let auditTs = obj.removeValue(forKey: "_audit_timestamp") {
            if obj["timestamp"] == nil {
                obj["timestamp"] = auditTs
            }
        }

        obj.removeValue(forKey: "session_id")

        guard let out = try? JSONSerialization.data(withJSONObject: obj, options: []),
              let str = String(data: out, encoding: .utf8)
        else { return nil }
        return str
    }
}
