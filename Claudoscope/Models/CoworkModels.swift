import Foundation

// MARK: - Availability

enum CoworkAvailability: Sendable, Equatable {
    case unknown
    case notConfigured
    case configuredButEmpty(ownerId: String)
    case ready(ownerId: String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var ownerId: String? {
        switch self {
        case .configuredButEmpty(let id), .ready(let id):
            return id
        case .unknown, .notConfigured:
            return nil
        }
    }
}

// MARK: - Session

struct CoworkSession: Identifiable, Sendable, Hashable {
    let sessionId: String
    let projectId: String
    let cliSessionId: String?
    let processName: String?
    let title: String?
    let initialMessage: String?
    let model: String?
    let cwd: String?
    let createdAt: Date?
    let lastActivityAt: Date?
    let effectiveLastActivity: Date
    let isArchived: Bool
    let detectedFiles: [String]
    let slashCommandNames: [String]
    let metadataURL: URL
    let transcriptURL: URL?

    var id: String { sessionId }

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let processName, !processName.isEmpty { return processName }
        return String(sessionId.prefix(8))
    }
}

// MARK: - Decode helpers

enum CoworkSessionDecoder {
    /// Decode a Cowork session metadata JSON file using JSONSerialization +
    /// defensive `as?` casts so unknown keys never break parsing. Timestamps
    /// are millisecond epochs in the Claude.app schema.
    static func decode(metadataURL: URL, projectId: String) -> CoworkSession? {
        guard let data = try? Data(contentsOf: metadataURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let sessionId = (json["sessionId"] as? String) ?? metadataURL
            .deletingPathExtension()
            .lastPathComponent
            .replacingOccurrences(of: "local_", with: "")

        let createdAt = millisecondsAsDate(json["createdAt"])
        let lastActivityAt = millisecondsAsDate(json["lastActivityAt"])
        let mtime = (try? metadataURL.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate)
        let effective = [lastActivityAt, createdAt, mtime].compactMap { $0 }.max() ?? .distantPast

        let transcriptCandidate = metadataURL
            .deletingPathExtension()
            .appendingPathComponent("audit.jsonl")
        let transcriptURL: URL? = FileManager.default
            .fileExists(atPath: transcriptCandidate.path) ? transcriptCandidate : nil

        return CoworkSession(
            sessionId: sessionId,
            projectId: projectId,
            cliSessionId: json["cliSessionId"] as? String,
            processName: json["processName"] as? String,
            title: (json["title"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            initialMessage: json["initialMessage"] as? String,
            model: json["model"] as? String,
            cwd: json["cwd"] as? String,
            createdAt: createdAt,
            lastActivityAt: lastActivityAt,
            effectiveLastActivity: effective,
            isArchived: (json["isArchived"] as? Bool) ?? false,
            detectedFiles: parseDetectedFiles(json["fsDetectedFiles"]),
            slashCommandNames: parseSlashCommands(json["slashCommands"]),
            metadataURL: metadataURL,
            transcriptURL: transcriptURL
        )
    }

    private static func millisecondsAsDate(_ value: Any?) -> Date? {
        guard let ms = value as? Double else {
            if let intMs = value as? Int { return Date(timeIntervalSince1970: Double(intMs) / 1000) }
            return nil
        }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    /// Cowork's `fsDetectedFiles` has been observed as both `[String]` and
    /// `[{"path": "..."}]`. Accept either, drop anything else.
    private static func parseDetectedFiles(_ value: Any?) -> [String] {
        guard let raw = value as? [Any] else { return [] }
        return raw.compactMap { entry in
            if let s = entry as? String { return s }
            if let dict = entry as? [String: Any], let path = dict["path"] as? String { return path }
            return nil
        }
    }

    /// `slashCommands` entries can be `{"name": "..."}` dicts or bare strings.
    private static func parseSlashCommands(_ value: Any?) -> [String] {
        guard let raw = value as? [Any] else { return [] }
        return raw.compactMap { entry in
            if let s = entry as? String { return s }
            if let dict = entry as? [String: Any], let name = dict["name"] as? String { return name }
            return nil
        }
    }
}
