import SwiftUI

// MARK: - Rule & Category Metadata

struct RuleMetadata {
    let displayName: String
    let hint: String
}

let ruleMetadata: [LintCheckId: RuleMetadata] = [
    .SEC001: RuleMetadata(
        displayName: "Private key detected",
        hint: "Private key material found in session output. Never paste private keys into prompts. Use file references or environment variables instead."
    ),
    .SEC002: RuleMetadata(
        displayName: "AWS access key detected",
        hint: "Found AWS access key pattern (AKIA...) in session output. Use environment variables or a secrets manager instead of hardcoding credentials."
    ),
    .SEC003: RuleMetadata(
        displayName: "Authorization header detected",
        hint: "Bearer token found in session content. Ensure auth headers are sourced from env vars, not pasted inline."
    ),
    .SEC004: RuleMetadata(
        displayName: "API key or token detected",
        hint: "Generic API key pattern matched. Rotate the key and move it to a .env file or secrets vault."
    ),
    .SEC005: RuleMetadata(
        displayName: "Password or secret literal detected",
        hint: "Plaintext password or secret found in session content. Use a secrets manager or environment variables."
    ),
    .SEC006: RuleMetadata(
        displayName: "Connection string with credentials",
        hint: "Database connection string with embedded credentials detected. Move credentials to environment variables."
    ),
    .SEC007: RuleMetadata(
        displayName: "Platform token detected",
        hint: "Platform-specific token (GitHub, Slack, npm, etc.) found. Rotate the token and store it securely."
    ),
    .SEC008: RuleMetadata(
        displayName: "Credentials exposed without ENV_SCRUB",
        hint: "Credential patterns found in session data while CLAUDE_CODE_SUBPROCESS_ENV_SCRUB is not set. Credentials may leak into Bash tool, hooks, or MCP server subprocesses."
    ),
    .SES001: RuleMetadata(
        displayName: "High cost session",
        hint: "Session estimated cost exceeds $25. Consider breaking expensive tasks into smaller sessions."
    ),
    .SES002: RuleMetadata(
        displayName: "Frequent context compaction",
        hint: "Session triggered multiple compaction cycles, indicating repeated context window saturation. Earlier decisions and instructions get lost each cycle."
    ),
    .SES003: RuleMetadata(
        displayName: "High cost session",
        hint: "Session exceeded expected spending. Consider breaking expensive tasks into smaller sessions to keep per-session costs manageable."
    ),
    .SES004: RuleMetadata(
        displayName: "Stale session with history",
        hint: "Session has significant history but hasn't been active recently. Consider archiving or reviewing for relevant context."
    ),
    .SES005: RuleMetadata(
        displayName: "Session errors detected",
        hint: "Session experienced API errors (rate limits, auth failures, etc.). Check API configuration and consider request throttling."
    ),
    .SES006: RuleMetadata(
        displayName: "Idle session resumed without /clear",
        hint: "Session resumed after 75+ minutes idle without /clear. Stale context forces full re-caching, wasting tokens and cost."
    ),
    .SKL001: RuleMetadata(
        displayName: "Wrong SKILL.md casing",
        hint: "Skill manifest file should be named SKILL.md (uppercase). Rename to match expected convention."
    ),
    .SKL002: RuleMetadata(
        displayName: "Missing skill name",
        hint: "Skill YAML frontmatter is missing the 'name' field. Add a kebab-case name to the frontmatter."
    ),
    .SKL003: RuleMetadata(
        displayName: "Missing skill description",
        hint: "Skill YAML frontmatter is missing the 'description' field. Add a clear description of what the skill does."
    ),
    .SKL004: RuleMetadata(
        displayName: "Name/directory mismatch",
        hint: "Skill name in frontmatter doesn't match the containing directory name. Align them for consistency."
    ),
    .SKL005: RuleMetadata(
        displayName: "Name not kebab-case",
        hint: "Skill name should use kebab-case (lowercase with hyphens). Rename to match the convention."
    ),
    .SKL006: RuleMetadata(
        displayName: "Name exceeds 64 characters",
        hint: "Skill name is too long. Shorten it to 64 characters or fewer."
    ),
    .SKL007: RuleMetadata(
        displayName: "Description exceeds 1024 characters",
        hint: "Skill description is too long. Keep it concise, under 1024 characters."
    ),
    .SKL008: RuleMetadata(
        displayName: "XML brackets in frontmatter",
        hint: "Skill YAML frontmatter contains raw XML brackets which can break the system prompt parser. Escape them or move to the body."
    ),
    .SKL009: RuleMetadata(
        displayName: "Reserved word in skill name",
        hint: "Skill name uses a reserved word. Choose a different name to avoid conflicts."
    ),
    .SKL012: RuleMetadata(
        displayName: "Skill body exceeds 500 lines",
        hint: "Skill body is very long. Consider splitting into smaller, focused skills."
    ),
    .SKL_AGG: RuleMetadata(
        displayName: "Aggregate descriptions over budget",
        hint: "Combined skill descriptions exceed the 16,000 character budget. Trim descriptions to stay within limits."
    ),
    .CMD001: RuleMetadata(
        displayName: "CLAUDE.md exceeds 200 lines",
        hint: "Your CLAUDE.md is getting long. Consider splitting into a .claude/rules/ directory for better organization."
    ),
    .CMD002: RuleMetadata(
        displayName: "Large CLAUDE.md without rules directory",
        hint: "CLAUDE.md has over 100 lines but no .claude/rules/ directory. Split sections into separate rule files."
    ),
    .CMD003: RuleMetadata(
        displayName: "File-type patterns inline",
        hint: "File-type glob patterns found inline in CLAUDE.md. Move them to .claude/rules/ with proper glob frontmatter."
    ),
    .CMD006: RuleMetadata(
        displayName: "Unclosed code block",
        hint: "CLAUDE.md contains an unclosed code block (mismatched backtick fences). Close it to prevent parsing issues."
    ),
    .CMD_IMPORT: RuleMetadata(
        displayName: "Deep @import chain",
        hint: "Import chain exceeds 5 hops. Flatten imports to reduce complexity and improve readability."
    ),
    .CMD_DEPRECATE: RuleMetadata(
        displayName: ".claude/commands/ deprecated",
        hint: "The .claude/commands/ directory is deprecated. Migrate to .claude/rules/ for the new convention."
    ),
    .RUL001: RuleMetadata(
        displayName: "Malformed YAML frontmatter",
        hint: "Rule file has invalid YAML frontmatter. Check for syntax errors and fix the YAML."
    ),
    .RUL002: RuleMetadata(
        displayName: "Invalid glob syntax",
        hint: "Glob pattern in rule frontmatter has invalid syntax. Check for unmatched brackets or invalid characters."
    ),
    .RUL003: RuleMetadata(
        displayName: "Glob matches no files",
        hint: "The glob pattern in this rule doesn't match any files. Verify the pattern targets existing paths."
    ),
    .RUL005: RuleMetadata(
        displayName: "Rule exceeds 100 lines",
        hint: "Rule file is over 100 lines. Consider splitting into smaller, focused rules."
    ),
    .XCT001: RuleMetadata(
        displayName: "Config token estimate",
        hint: "Your CLAUDE.md and settings consume an estimated portion of the context window. Consider trimming if you see frequent compactions."
    ),
    .XCT002: RuleMetadata(
        displayName: "Config tokens exceed 5000",
        hint: "Configuration exceeds 5,000 tokens. This significantly reduces available context. Trim or split your config."
    ),
    .XCT003: RuleMetadata(
        displayName: "No .claude/ directory",
        hint: "No .claude/ directory found. Create one to configure Claude Code for this project."
    ),
    .CFG001: RuleMetadata(
        displayName: "Sandbox enabled without lock files",
        hint: "sandbox.enabled is true but no dependency lock files found. Sandbox may silently disable if required tools are missing."
    ),
    .CFG002: RuleMetadata(
        displayName: "Contradictory filesystem permissions",
        hint: "Same path appears in both allowRead and denyRead. Remove the conflict so permissions behave predictably."
    ),
    .CFG003: RuleMetadata(
        displayName: "Claude.ai MCP servers disabled",
        hint: "ENABLE_CLAUDEAI_MCP_SERVERS is set to false. Claude.ai MCP servers will not be available."
    ),
    .CFG004: RuleMetadata(
        displayName: "Enterprise plugin control active",
        hint: "allowedChannelPlugins is configured, restricting which plugins are available in this environment."
    ),
    .CFG005: RuleMetadata(
        displayName: "Bare mode conflicts with hooks/MCP",
        hint: "Bare mode is enabled but hooks or MCP servers are also configured. These are ignored in bare mode."
    ),
    .CFG006: RuleMetadata(
        displayName: "Subprocess env scrub not enabled",
        hint: "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB is not set. Credentials from your shell environment may leak into Bash tool, hooks, and MCP server subprocesses."
    ),
]

struct CategoryDef: Identifiable {
    let id: String
    let label: String
    let icon: String
    let color: Color
    let prefixes: [String]
    let sortOrder: Int
}

let healthCategories: [CategoryDef] = [
    CategoryDef(id: "security", label: "Security", icon: "!", color: Color(red: 0.886, green: 0.294, blue: 0.290), prefixes: ["SEC"], sortOrder: 1),
    CategoryDef(id: "performance", label: "Session performance", icon: "~", color: Color(red: 0.937, green: 0.624, blue: 0.153), prefixes: ["SES"], sortOrder: 2),
    CategoryDef(id: "skills", label: "Skills & hooks", icon: "S", color: Color(red: 0.498, green: 0.467, blue: 0.867), prefixes: ["SKL", "HKS"], sortOrder: 3),
    CategoryDef(id: "config", label: "Configuration", icon: "i", color: Color(red: 0.216, green: 0.541, blue: 0.867), prefixes: ["XCT", "CFG", "CMD", "RUL"], sortOrder: 4),
]

let otherCategory = CategoryDef(id: "other", label: "Other", icon: "?", color: .gray, prefixes: [], sortOrder: 99)

func categoryFor(_ checkId: LintCheckId) -> CategoryDef {
    let raw = checkId.rawValue
    for cat in healthCategories {
        for prefix in cat.prefixes {
            if raw.hasPrefix(prefix) { return cat }
        }
    }
    return otherCategory
}

func displayNameFor(_ checkId: LintCheckId) -> String {
    ruleMetadata[checkId]?.displayName ?? checkId.rawValue
}

func hintFor(_ checkId: LintCheckId) -> String? {
    ruleMetadata[checkId]?.hint
}
