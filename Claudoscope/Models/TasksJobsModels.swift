import Foundation

// MARK: - Agent Task Lists (~/.claude/tasks/<uuid>/N.json)

/// One task from a session's TaskCreate/TodoWrite list.
struct AgentTaskItem: Identifiable, Sendable, Decodable {
    let id: String
    let subject: String?
    let description: String?
    let activeForm: String?
    let status: String?         // "pending", "in_progress", "completed"
    let blocks: [String]?
    let blockedBy: [String]?

    var isCompleted: Bool { status == "completed" }
}

/// One task-list directory under ~/.claude/tasks/, keyed by the owning
/// session/agent uuid.
struct TaskListSummary: Identifiable, Sendable {
    var id: String { sessionId }
    let sessionId: String
    let tasks: [AgentTaskItem]
    let modifiedAt: Date?

    var openCount: Int { tasks.filter { !$0.isCompleted }.count }
    var completedCount: Int { tasks.filter(\.isCompleted).count }
}

// MARK: - Background Jobs (~/.claude/jobs/<shortHash>/)

/// Decoded from a job directory's state.json. providerEnv is deliberately
/// never decoded: it is an env map that can carry API keys, and having no
/// CodingKey for it is the mask.
struct JobSummary: Identifiable, Sendable, Decodable {
    var id: String { dirName }
    var dirName: String = ""    // stamped by the service after decode
    let name: String?
    let state: String?          // "done", "running", ...
    let detail: String?
    let sessionId: String?
    let resumeSessionId: String?
    let cwd: String?
    let template: String?
    let backend: String?
    let tokens: Int?
    let inFlight: JobInFlight?
    let output: JobOutput?
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case name, state, detail, sessionId, resumeSessionId, cwd
        case template, backend, tokens, inFlight, output, createdAt, updatedAt
    }
}

struct JobInFlight: Sendable, Decodable {
    let tasks: Int?
    let queued: Int?
}

struct JobOutput: Sendable, Decodable {
    let result: String?
}

/// One line of a job's timeline.jsonl.
struct JobTimelineEntry: Identifiable, Sendable, Decodable {
    var id: String { (at ?? "") + "|" + (state ?? "") + "|" + (detail ?? "") }
    let at: String?
    let state: String?
    let detail: String?
    let text: String?
}

/// ~/.claude/daemon.status.json, written by the background-job supervisor.
struct DaemonStatus: Sendable, Decodable {
    let supervisorPid: Int?
    let writtenAt: Double?      // epoch millis
}
