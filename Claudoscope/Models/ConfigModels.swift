import Foundation

// MARK: - Hook Models

enum HookSource: Sendable, Hashable {
    case user
    case project(name: String)
    case local(name: String)
    case plugin(name: String)
    case managed

    var label: String {
        switch self {
        case .user: return "user"
        case .project(let name): return "project: \(name)"
        case .local(let name): return "local: \(name)"
        case .plugin(let name): return "plugin: \(name)"
        case .managed: return "managed"
        }
    }
}

struct HookCommand: Sendable {
    let type: String?       // "command"
    let command: String
    let timeout: Int?
    var terminalSequence: String? = nil   // hook terminalSequence field (CC 2.1.141)
}

struct HookRule: Identifiable, Sendable {
    let id: String          // generated UUID
    let matcher: String     // tool matcher, or "*" for catch-all
    let hooks: [HookCommand]
    let source: HookSource
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
    var allowedTools: [String]? = nil      // frontmatter allowed-tools (CC 2.1.152)
    var disallowedTools: [String]? = nil   // frontmatter disallowed-tools (CC 2.1.152)
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
    var allowedTools: [String]? = nil      // frontmatter allowed-tools (CC 2.1.152)
    var disallowedTools: [String]? = nil   // frontmatter disallowed-tools (CC 2.1.152)
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

// MARK: - Extended Config Models

struct SandboxConfig: Sendable {
    let unsandboxedCommands: [String]
    let enableWeakerNestedSandbox: Bool
    let deniedDomains: [String]
}

struct AttributionConfig: Sendable {
    let commitTemplate: String?
    let prTemplate: String?
    let hasDeprecatedCoAuthoredBy: Bool
}

/// One drillable component a plugin contributes (a skill, agent, command, or
/// config file), with the file to display when the user clicks it.
struct PluginComponentEntry: Identifiable, Hashable, Sendable {
    var id: String { path }
    let name: String
    let path: String
}

struct PluginInfo: Identifiable, Sendable {
    var id: String { fullName }
    let fullName: String
    let name: String
    let marketplace: String?
    let enabled: Bool
    var components: [String]? = nil     // commands/skills/hooks contributed (CC 2.1.143/2.1.145)
    var dependencies: [String]? = nil   // declared plugin dependencies (CC 2.1.143)
    var componentsByKind: [String: [PluginComponentEntry]]? = nil   // kind -> entries (name + file path), for drill-down
}

struct MarketplaceSource: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let sourceType: String
    let detail: String
}

struct ClaudeProfile: Sendable {
    let numStartups: Int?
    let theme: String?
    let autoUpdatesChannel: String?
    let hasCompletedOnboarding: Bool?
    let lastOnboardingVersion: String?
    let lastReleaseNotesSeen: String?
    let shiftEnterKeyBindingInstalled: Bool?
    let maskedEmail: String?
    let orgRole: String?
}

struct AutoModeConfig: Sendable {
    let hardDeny: [String]      // autoMode.hard_deny rules
    let environment: [String]   // autoMode.environment trusted entries
}

struct ExtendedConfig: Sendable {
    let sandbox: SandboxConfig?
    let skipDangerousModePermissionPrompt: Bool
    let disableSkillShellExecution: Bool
    let attribution: AttributionConfig?
    let prUrlTemplate: String?
    let plugins: [PluginInfo]
    let marketplaces: [MarketplaceSource]
    let profile: ClaudeProfile?
    var autoMode: AutoModeConfig? = nil       // settings.json autoMode block (CC 2.1.136)
    var allowAllClaudeAiMcps: Bool? = nil     // managed setting (CC 2.1.149)
}

// MARK: - Theme Models

struct ThemeFile: Identifiable, Sendable {
    var id: String { name }
    let name: String          // filename without .json
    let path: String
    let mtime: Date?
    let isActive: Bool        // matches ~/.claude.json's `theme` field
}
