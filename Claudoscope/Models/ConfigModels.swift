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

enum McpAuthStatus: Sendable, Equatable {
    case notApplicable   // stdio server (no OAuth)
    case authenticated   // http server not flagged as needing login (best-effort)
    case needsLogin      // http server present in the needs-auth cache
    case expired
    case unknown
}

struct McpServerEntry: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let command: String?
    let args: [String]
    let url: String?
    let env: [String: String]
    let level: String?      // "global", "project", "local"
    var authStatus: McpAuthStatus = .notApplicable
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

// MARK: - Agent Models

enum AgentSource: Sendable, Equatable {
    case user
    case project(name: String)
    case plugin(name: String)

    var isUser: Bool { if case .user = self { return true }; return false }

    var label: String {
        switch self {
        case .user:           return "user"
        case .project(let n): return "project: \(n)"
        case .plugin(let n):  return "plugin: \(n)"
        }
    }
}

struct AgentEntry: Identifiable, Sendable {
    var id: String { displayName }
    let name: String                    // frontmatter `name` (filename fallback)
    let displayName: String             // unique; source suffix for plugin/project
    let description: String?
    let metadata: [String: String]      // normalized: model, effort, tools, disallowed-tools, maxTurns, skills, ...
    let body: String
    let sizeBytes: Int
    let source: AgentSource

    /// Core routing roles from the user's agent-routing convention. Only
    /// user-scoped agents qualify (a plugin/project "builder" is not the routing builder).
    static let routingNames: Set<String> = [
        "recon", "explore", "routine", "builder", "checker",
        "security-review", "security-build",
    ]
    static let routingOrder: [String] = [
        "recon", "explore", "routine", "builder", "checker",
        "security-review", "security-build",
    ]

    var isRoutingAgent: Bool {
        source.isUser && Self.routingNames.contains(name.lowercased())
    }
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

struct SandboxCredentials: Sendable {
    let files: [String]      // sandbox.credentials.files paths
    let envVars: [String]    // sandbox.credentials.envVars names
    /// Entry path/name -> declared `mode` ("deny" or "mask"). Masking (CC 2.1.221/.224)
    /// substitutes the real value on egress instead of hiding the file outright, and
    /// only works when the sandbox terminates TLS. Absent entries default to "deny".
    var modes: [String: String] = [:]
}

struct SandboxConfig: Sendable {
    let unsandboxedCommands: [String]
    let enableWeakerNestedSandbox: Bool
    let deniedDomains: [String]
    var credentials: SandboxCredentials? = nil   // sandbox.credentials (CC 2.1.187)
    var allowAppleEvents: Bool = false            // sandbox.allowAppleEvents (CC 2.1.181)
    var filesystemDisabled: Bool = false          // sandbox.filesystem.disabled (CC 2.1.216)
    var strictAllowlist: Bool = false             // sandbox.network.strictAllowlist (CC 2.1.219)
    var tlsTerminate: Bool = false                // sandbox.network.tlsTerminate
    /// bwrapPath / socatPath / ripgrep. Honored only from user, managed, and
    /// --settings scope since CC 2.1.232.
    var binaryOverrides: [String: String] = [:]
}

struct AttributionConfig: Sendable {
    let commitTemplate: String?
    let prTemplate: String?
    let hasDeprecatedCoAuthoredBy: Bool
    var omitSessionUrl: Bool = false              // attribution.sessionUrl == false (CC 2.1.183)
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
    var classifyAllShell: Bool = false   // autoMode.classifyAllShell (CC 2.1.193)
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
    var cleanupPeriodDays: Int? = nil         // settings.json transcript retention (default 30)
    var respondToBashCommands: Bool? = nil    // CC 2.1.186 (default true)
    var availableModels: [String] = []        // model allowlist
    var enforceAvailableModels: Bool = false  // managed (CC 2.1.175)
    var requiredMinimumVersion: String? = nil // managed (CC 2.1.163)
    var requiredMaximumVersion: String? = nil // managed (CC 2.1.163)
    var crossSessionInbound: String? = nil    // accept|hold|refuse (CC 2.1.224)
    var dialogExpiry: Int? = nil              // CC 2.1.224
    var workflowSizeGuideline: String? = nil  // CC 2.1.219
    var spellcheck: Bool? = nil               // CC 2.1.235
    var emojiCompletionEnabled: Bool? = nil   // CC 2.1.217
    var defaultModel: String? = nil           // env ANTHROPIC_DEFAULT_MODEL (CC 2.1.236)
}

// MARK: - Theme Models

struct ThemeFile: Identifiable, Sendable {
    var id: String { name }
    let name: String          // filename without .json
    let path: String
    let mtime: Date?
    let isActive: Bool        // matches ~/.claude.json's `theme` field
}
