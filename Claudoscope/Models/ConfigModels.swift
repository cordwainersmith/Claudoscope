import Foundation

// MARK: - Hook Models

struct HookCommand: Sendable {
    let type: String?       // "command"
    let command: String
    let timeout: Int?
}

struct HookRule: Identifiable, Sendable {
    let id: String          // generated UUID
    let matcher: String     // tool matcher, or "*" for catch-all
    let hooks: [HookCommand]
}

struct HookEventGroup: Identifiable, Sendable {
    var id: String { event }
    let event: String       // "PreToolUse", "PostToolUse", etc.
    let rules: [HookRule]
}

// MARK: - MCP Models

struct McpServerEntry: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let command: String?
    let args: [String]
    let url: String?
    let env: [String: String]
    let level: String?      // "global", "project", "local"
}

// MARK: - Command Models

struct CommandEntry: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let description: String?
    let content: String
    let sizeBytes: Int
}

// MARK: - Skill Models

struct SkillEntry: Identifiable, Sendable {
    var id: String { displayName }
    let name: String
    let displayName: String
    let description: String?
    let metadata: [String: String]
    let body: String
    let sizeBytes: Int
}

// MARK: - Memory Models

struct MemoryFile: Identifiable, Sendable {
    let id: String          // "global", "project", "memory"
    let label: String       // "CLAUDE.md", "MEMORY.md"
    let sublabel: String    // "global", "project", "auto-memory"
    let path: String
    let content: String?
    let sizeBytes: Int?
}
