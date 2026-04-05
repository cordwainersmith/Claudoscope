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

// MARK: - Extended Config Models

struct SandboxConfig: Sendable {
    let unsandboxedCommands: [String]
    let enableWeakerNestedSandbox: Bool
}

struct AttributionConfig: Sendable {
    let commitTemplate: String?
    let prTemplate: String?
    let hasDeprecatedCoAuthoredBy: Bool
}

struct PluginInfo: Identifiable, Sendable {
    var id: String { fullName }
    let fullName: String
    let name: String
    let marketplace: String?
    let enabled: Bool
}

struct MarketplaceSource: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let sourceType: String
    let detail: String
}

struct ClaudeAccountProfile: Sendable {
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

struct ExtendedConfig: Sendable {
    let sandbox: SandboxConfig?
    let skipDangerousModePermissionPrompt: Bool
    let attribution: AttributionConfig?
    let plugins: [PluginInfo]
    let marketplaces: [MarketplaceSource]
    let profile: ClaudeAccountProfile?
}
