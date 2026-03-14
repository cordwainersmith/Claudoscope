import Foundation

/// Reads and parses ~/.claude/history.jsonl into HistoryEntry values.
actor TimelineService {
    private let historyFile: URL

    init(claudeDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")) {
        self.historyFile = claudeDir.appendingPathComponent("history.jsonl")
    }

    /// Load history entries, optionally filtered by date and limited in count.
    /// Returns entries sorted newest first.
    func loadEntries(since: Date? = nil, limit: Int? = nil) async -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: historyFile),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }

        let lines = content.components(separatedBy: .newlines)
        var entries: [HistoryEntry] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            let display = json["display"] as? String ?? ""
            if display.isEmpty { continue }

            // Timestamp is Unix milliseconds
            guard let tsValue = json["timestamp"] as? Double else { continue }
            let timestamp = Date(timeIntervalSince1970: tsValue / 1000.0)

            if let since, timestamp < since {
                continue
            }

            let entry = HistoryEntry(
                id: UUID().uuidString,
                type: json["type"] as? String ?? "conversation",
                sessionId: json["sessionId"] as? String,
                project: json["project"] as? String,
                projectId: json["projectId"] as? String,
                timestamp: timestamp,
                display: display.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            entries.append(entry)
        }

        // Sort newest first
        entries.sort { $0.timestamp > $1.timestamp }

        if let limit {
            return Array(entries.prefix(limit))
        }

        return entries
    }
}
