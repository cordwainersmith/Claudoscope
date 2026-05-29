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
    .CFG007: RuleMetadata(
        displayName: "Skill shell execution enabled",
        hint: "disableSkillShellExecution is not set. Skills can invoke shell commands through the Bash tool. Set to true in settings.json to restrict this."
    ),

    // MARK: Hardening baseline (HRD001-HRD011)

    .HRD001: RuleMetadata(
        displayName: "Sandbox not enabled",
        hint: "Verifies sandbox.enabled is true in settings.json. The sandbox is Claude Code's process-level isolation: it restricts every tool call (Bash, Read, Write, network) to the configured allow lists. Without it, a single prompt-injection attack or compromised MCP server runs with the user's full permissions and can read SSH keys, exfiltrate ~/.aws credentials, or write to ~/.zshrc to persist code execution across shell sessions. Enabling the sandbox closes the blast radius to the explicitly trusted set."
    ),
    .HRD002: RuleMetadata(
        displayName: "Missing baseline deny rule",
        hint: "Confirms each high-risk command pattern from the hardening baseline is present in permissions.deny — Claude Code's hard, non-bypassable filter. Entries like Bash(rm -rf /), Bash(curl * | sh), and Read(.ssh/**) block destructive commands and credential exfiltration even when the user explicitly asks for them, defending against typos, prompt-injection attacks, and agentic loops gone wrong. Reinstall the baseline to merge the full set."
    ),
    .HRD003: RuleMetadata(
        displayName: "Hardening hook not registered",
        hint: "Verifies an expected claudoscope-*.sh hook is wired into a PreToolUse Bash matcher in settings.json. Hooks are Claude Code's runtime veto layer — they execute before each tool call and can block it. An unregistered hook still exists on disk but never fires, so the threats it catches (lockfile tampering, suspicious chmod, fresh-package supply-chain attacks, public-repo pushes) reach the agent unintercepted. Reinstall to restore the registration."
    ),
    .HRD004: RuleMetadata(
        displayName: "Hook script missing on disk",
        hint: "Checks that every command path registered under hooks.* actually exists on disk. A registered-but-missing hook silently fails: Claude Code logs the error but the protection is gone, leaving a gap an attacker can exploit by deleting the script while leaving the registration intact. Reinstall the baseline to redeploy the script, or strip the dangling registration if the hook was removed deliberately."
    ),
    .HRD005: RuleMetadata(
        displayName: "Hook script not executable",
        hint: "Confirms each registered hook script has its owner-execute bit set. Without it, Claude Code skips the hook and the protection is silently lost — the same effective state as a missing file, but easier to overlook because the script and the registration both still appear correct. Run chmod 0755 on the file, or reinstall the baseline."
    ),
    .HRD006: RuleMetadata(
        displayName: "Hook script tampered",
        hint: "Compares each on-disk hook script's SHA-256 against the bundled checksum sidecar. A drifted hash means the script was modified after install — by a benign upgrade, a backup restore, or a malicious tamper. Because hooks are a privileged runtime layer, an attacker who flips one to always-allow defeats every Layer 2 check while leaving the install marker untouched. Reinstall to restore the canonical version."
    ),
    .HRD007: RuleMetadata(
        displayName: "Hook script world-writable",
        hint: "Checks that hook scripts are not world-writable. A world-writable hook can be modified by any local user or compromised process, defeating the integrity guarantee that HRD006 depends on — the SHA check is meaningless if the file can be silently overwritten between scans. Run chmod o-w on the file, or reinstall the baseline."
    ),
    .HRD008: RuleMetadata(
        displayName: "autoMode block missing",
        hint: "Checks that settings.json has an autoMode block. autoMode governs the agent's behavior when running unattended (long-running tasks, batch jobs); without it, soft-deny rules and the trusted-environment list are unset, so the agent can force-push, auto-commit, or hit arbitrary external APIs without intent confirmation. This is the safety rail for unsupervised agent runs. Reinstall to add the Layer 3 defaults."
    ),
    .HRD009: RuleMetadata(
        displayName: "Overly permissive trusted host",
        hint: "Flags trusted-host entries that use an unbounded wildcard (e.g. '*' or '*.com'). A wildcard like '*' turns the allow list into a no-op — every outbound connection is permitted and the sandbox network protection collapses. A TLD-level wildcard ('*.com', '*.io') has the same problem at smaller scale, accidentally trusting every site under that suffix. Tighten the entry through the Trusted Sources sheet to the specific subdomain you actually need."
    ),
    .HRD010: RuleMetadata(
        displayName: "Governance block missing or drifted",
        hint: "Checks that the marker-wrapped governance block is present in ~/.claude/CLAUDE.md and matches the bundled baseline. CLAUDE.md is the agent's standing context, loaded at every session start — it carries advisory rules (no auto-commit, no force-push without intent, scrub credentials in output) that complement the hard hooks. If the block is stripped or modified, the agent loses these soft guardrails even though Layers 1 and 2 still hold. Reinstall to refresh."
    ),
    .HRD011: RuleMetadata(
        displayName: "Security-awareness skill missing or drifted",
        hint: "Checks that claudoscope-security-awareness.md is present in ~/.claude/skills/ and matches the bundled baseline. Skills are on-demand reference material the agent can consult mid-task — this one encodes the threat model behind the hardening baseline so when the agent hits a borderline situation (a curl invocation, a sudo prompt, a credential request), it has the rationale for refusing without needing the user to re-explain it each time. Reinstall to redeploy."
    ),
    .SKL013: RuleMetadata(
        displayName: "Tool restriction malformed",
        hint: "A skill's allowed-tools / disallowed-tools frontmatter is malformed or self-contradictory (a tool listed as both allowed and disallowed, or an unknown tool name). Fix the frontmatter so the restriction is unambiguous."
    ),
    .CMD007: RuleMetadata(
        displayName: "Command tool restriction malformed",
        hint: "A command's allowed-tools / disallowed-tools frontmatter is malformed or self-contradictory. Fix the frontmatter so the restriction is unambiguous."
    ),
    .CFG008: RuleMetadata(
        displayName: "All claude.ai MCP servers trusted",
        hint: "allowAllClaudeAiMcps is enabled, which trusts every claude.ai MCP server without per-server review. Disable it and allow only the MCP servers you intend to use."
    ),
    .HRD012: RuleMetadata(
        displayName: "autoMode missing hard_deny baseline",
        hint: "settings.json has an autoMode block but no hard_deny baseline. hard_deny rules are the non-bypassable stops for unattended runs; without them the agent can take destructive actions autonomously during long or batch jobs. Add a hard_deny baseline."
    ),
    .PLG001: RuleMetadata(
        displayName: "Unsatisfied plugin dependency",
        hint: "A plugin declares a dependency that is not installed or enabled. Install or enable the dependency, or remove the requirement."
    ),
    .PLG002: RuleMetadata(
        displayName: "Plugin dependency cycle",
        hint: "Plugin dependencies form a cycle (A depends on B which depends back on A). Break the cycle so load order is well-defined."
    ),
    .PLG003: RuleMetadata(
        displayName: "Plugin contributes no components",
        hint: "A plugin contributes no commands, skills, or hooks. It may be misconfigured or an empty install."
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
    CategoryDef(id: "plugins", label: "Plugins", icon: "P", color: Color(red: 0.357, green: 0.678, blue: 0.518), prefixes: ["PLG"], sortOrder: 5),
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

// MARK: - Auto-Fix Support

let autoFixableRules: Set<LintCheckId> = [.CFG006, .HRD001, .HRD002, .HRD005, .HRD007]

/// Hardcoded inline copy of the layer1 critical deny entries. Mirrors
/// `Claudoscope/Resources/HardeningBaseline/layer1-permissions.json` so the
/// HRD002 fix works even if the bundle resource is missing.
let hardeningCriticalDenyEntries: [String] = [
    "Bash(rm -rf /)",
    "Bash(rm -rf ~)",
    "Bash(rm -rf $HOME)",
    "Bash(curl * | sh)",
    "Bash(curl * | bash)",
    "Bash(wget * | sh)",
    "Bash(wget * | bash)",
    "Bash(sudo *)",
    "Bash(chmod 777 *)",
    "Bash(git push --force *)",
    "Bash(git push -f *)",
    "Bash(git reset --hard *)",
    "Bash(eval *)"
]

struct ConfigAutoFixer {
    static func canFix(_ checkId: LintCheckId) -> Bool {
        autoFixableRules.contains(checkId)
    }

    static func apply(checkId: LintCheckId, settingsPath: String) -> Bool {
        switch checkId {
        case .CFG006:
            return addEnvVar(key: "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB", value: "1", settingsPath: settingsPath)
        case .HRD001:
            return enableSandbox(settingsPath: settingsPath)
        case .HRD002:
            return appendMissingDenyEntries(settingsPath: settingsPath)
        case .HRD005:
            return makeExecutable(filePath: settingsPath)
        case .HRD007:
            return removeWorldWritable(filePath: settingsPath)
        default:
            return false
        }
    }

    private static func addEnvVar(key: String, value: String, settingsPath: String) -> Bool {
        let url = URL(fileURLWithPath: settingsPath)
        guard let data = try? Data(contentsOf: url),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }

        var env = json["env"] as? [String: Any] ?? [:]
        env[key] = value
        json["env"] = env

        guard let outputData = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return false }

        return (try? outputData.write(to: url)) != nil
    }

    private static func enableSandbox(settingsPath: String) -> Bool {
        let url = URL(fileURLWithPath: settingsPath)
        guard let data = try? Data(contentsOf: url),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }

        var sandbox = json["sandbox"] as? [String: Any] ?? [:]
        sandbox["enabled"] = true
        json["sandbox"] = sandbox

        return atomicWriteJSON(json, to: url)
    }

    private static func appendMissingDenyEntries(settingsPath: String) -> Bool {
        let url = URL(fileURLWithPath: settingsPath)
        guard let data = try? Data(contentsOf: url),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }

        var permissions = json["permissions"] as? [String: Any] ?? [:]
        var deny = permissions["deny"] as? [String] ?? []
        let existing = Set(deny)
        for entry in hardeningCriticalDenyEntries where !existing.contains(entry) {
            deny.append(entry)
        }
        permissions["deny"] = deny
        json["permissions"] = permissions

        return atomicWriteJSON(json, to: url)
    }

    private static func makeExecutable(filePath: String) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: filePath) else { return false }
        do {
            let attrs = try fm.attributesOfItem(atPath: filePath)
            let current = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
            let next = current | 0o755
            try fm.setAttributes([.posixPermissions: NSNumber(value: next)], ofItemAtPath: filePath)
            return true
        } catch {
            return false
        }
    }

    private static func removeWorldWritable(filePath: String) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: filePath) else { return false }
        do {
            let attrs = try fm.attributesOfItem(atPath: filePath)
            let current = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
            let next = current & ~UInt16(0o002)
            try fm.setAttributes([.posixPermissions: NSNumber(value: next)], ofItemAtPath: filePath)
            return true
        } catch {
            return false
        }
    }

    private static func atomicWriteJSON(_ json: [String: Any], to url: URL) -> Bool {
        guard let outputData = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return false }
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp")
        do {
            try outputData.write(to: tmp, options: .atomic)
            _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
            return FileManager.default.fileExists(atPath: url.path)
        } catch {
            return false
        }
    }
}

func displayNameFor(_ checkId: LintCheckId) -> String {
    ruleMetadata[checkId]?.displayName ?? checkId.rawValue
}

func hintFor(_ checkId: LintCheckId) -> String? {
    ruleMetadata[checkId]?.hint
}

// MARK: - Per-entry rationale catalogs (HRD002, HRD003-HRD007)

/// Plain-English rationale for each deny-rule entry checked by HRD002.
/// Keyed by the literal entry string used in `permissions.deny`. When a row
/// represents a missing entry, this catalog explains *what that specific
/// command does* and *why blocking it matters* — written for someone who
/// isn't a security specialist.
let hardeningDenyRuleRationale: [String: String] = [
    // Destructive filesystem commands
    "Bash(rm -rf /)": "Blocks an attempt to delete every file on the system. The single character '/' is the root of the filesystem on macOS and Linux, so recursively removing it wipes the operating system and all your data. This pattern is the canonical example of a destructive prompt-injection payload — even if the agent believes it's running a 'cleanup script', this rule makes it impossible.",
    "Bash(rm -rf ~)": "Blocks deletion of your entire home directory. The '~' shortcut expands to /Users/yourname on macOS, so this command would erase every project, document, photo, and dotfile you own. The rule exists because a confused agent following an ambiguous instruction like 'clean up everything in my home folder' could otherwise produce catastrophic data loss.",
    "Bash(rm -rf $HOME)": "Blocks the environment-variable form of the home-directory wipe. $HOME and ~ both resolve to the same path, so this is the same threat as above expressed differently. Including both ensures the rule can't be sidestepped by switching syntax.",

    // Pipe-to-shell supply-chain attacks
    "Bash(curl * | sh)": "Blocks the classic 'pipe-to-shell' supply-chain attack pattern: download arbitrary code from the internet and execute it immediately, with zero opportunity to inspect or verify what's being run. Every 'curl ... | sh' invocation trusts whatever the remote server happens to send at that moment. This is the most common vector for npm, PyPI, and Homebrew supply-chain compromises.",
    "Bash(curl * | bash)": "Same threat as 'curl | sh', expressed with an explicit bash interpreter. Both forms appear in installer documentation across the web; blocking both closes the workaround of just changing the shell name.",
    "Bash(wget * | sh)": "Same pipe-to-shell pattern using wget instead of curl. wget is more common in CI scripts and Docker base images; blocking both download tools ensures the attack vector doesn't survive a tool swap.",
    "Bash(wget * | bash)": "Same as 'wget | sh' with the bash interpreter. The four pipe-to-shell variants (curl|sh, curl|bash, wget|sh, wget|bash) cover the common forms; blocking the full matrix prevents trivial bypass.",

    // Privilege escalation
    "Bash(sudo *)": "Blocks any command that escalates to root privileges. sudo runs as the system administrator, so an agent invoking it could install software, modify system files, or grant itself permanent access in ways that survive a session restart. Privilege escalation should never be automatic — if you need to install something with sudo, run it yourself outside the agent context.",
    "Bash(sudo:*)": "Variant of the sudo block using Claude Code's colon-glob syntax. Both 'sudo *' and 'sudo:*' match the same commands; including both ensures consistency between Claude Code's permissions matcher and the lint check, so neither pattern can be removed by accident without flagging.",

    // Permission misuse
    "Bash(chmod 777 *)": "Blocks setting a file's permissions to 'world-writable, world-executable'. Mode 777 is almost always a security mistake: it lets any user or process on the system overwrite or run the file. The common misuse pattern is an agent 'fixing' a permission-denied error by maximally opening permissions instead of granting the minimum needed.",

    // Git destructive operations
    "Bash(git push --force *)": "Blocks force-pushing to a remote branch. Force-push rewrites or deletes commits on the remote, destroying any teammate's work that was based on the original history. The agent should only force-push when you explicitly say 'force-push' and name the target branch — a bare 'push the changes' is too ambiguous to confirm intent.",
    "Bash(git push -f *)": "Same as 'git push --force', short form. Including both prevents the agent from working around the rule by switching to the abbreviated flag.",
    "Bash(git reset --hard *)": "Blocks discarding all local uncommitted changes. 'reset --hard' is irreversible: any work-in-progress not yet in a commit is gone. The agent should only run this when you've explicitly named the target (e.g., 'git reset --hard origin/main'); generic phrasing like 'undo my changes' or 'clean up the branch' isn't specific enough.",

    // Dynamic command execution
    "Bash(eval *)": "Blocks 'eval', which executes its argument as a shell command. eval expands variables in unpredictable ways and is the source of many shell-injection bugs. There is almost never a legitimate reason for an automation to use eval, and the rule blocks the entire class of dynamic-command-construction attacks.",

    // Credential file reads
    "Read(secrets/**)": "Blocks reading any file inside a 'secrets/' directory in any project. The 'secrets/' folder is the conventional location for API keys, certificates, and credentials; this rule ensures the agent can't accidentally include their content in chat output, paste them into commits, or leak them through session logs.",
    "Write(secrets/**)": "Blocks writing to anything in a 'secrets/' directory. Prevents the agent from creating new credential files in the wrong format, or overwriting existing ones with placeholder values that would silently break authentication for your services.",
    "Read(.netrc)": "Blocks reading ~/.netrc, where curl, wget, git, and many UNIX tools store username/password pairs for remote hosts. Reading the file would expose every saved credential at once.",
    "Write(.netrc)": "Blocks writing to ~/.netrc. Prevents the agent from corrupting your saved credentials or inserting attacker-controlled host entries that could redirect curl/wget/git to a malicious mirror.",
    "Read(.npmrc)": "Blocks reading .npmrc files, where npm stores authentication tokens for the npm registry. A leaked npm token can be used to publish malicious package versions under your account name — a classic supply-chain attack.",
    "Write(.npmrc)": "Blocks modifying .npmrc files. Prevents the agent from changing your registry URL (which could redirect installs to a malicious mirror) or rotating tokens silently.",
    "Read(.cargo/credentials.toml)": "Blocks reading Cargo's credentials file, where Rust's crates.io publish tokens are stored. Same threat profile as a leaked npm token — anyone with the token can publish malicious crates as you.",
    "Write(.cargo/credentials.toml)": "Blocks modifying Cargo's credentials file. Prevents silent token rotation or registry redirection.",
    "Read(.ssh/**)": "Blocks reading anything in ~/.ssh/. Private keys (id_rsa, id_ed25519, etc.) grant immediate remote-host compromise if leaked; known_hosts and config files reveal the map of every server you connect to. There is no scenario where the agent legitimately needs to read these files in conversation.",
    "Write(.ssh/**)": "Blocks writing to ~/.ssh/. Prevents an attacker from installing their own public key into authorized_keys for persistent backdoor access, or modifying ssh_config to route your traffic through a man-in-the-middle.",
    "Write(.claude/settings.json)": "Blocks the agent from modifying Claude Code's own primary settings file. If the agent could disable hooks, lift permissions, or rewrite the sandbox config, the entire hardening baseline becomes worthless. You retain full control by editing the file yourself.",
    "Write(.claude/settings.local.json)": "Blocks the agent from modifying Claude Code's local-overrides settings file. Same threat as the primary settings.json — local overrides take precedence, so an agent that can write here can effectively disable any baseline rule.",
]

/// Plain-English rationale for each hook script checked by HRD003-HRD007.
/// Keyed by script basename. Explains what that specific hook does and why
/// the runtime check matters.
let hardeningHookRationale: [String: String] = [
    "claudoscope-protect-file.sh": "Runs before every Write, Edit, or MultiEdit tool call. Blocks modifications to lockfiles (package-lock.json, Cargo.lock, pnpm-lock.yaml, etc.) and other generated files that should only change via the relevant package manager. Hand-edited lockfiles are a common source of supply-chain confusion and broken reproducibility.",
    "claudoscope-validate-commands.sh": "Runs before every Bash tool call. Catches dangerous command patterns the static permissions.deny list can't match — multiline scripts, unusual quoting, base64-encoded payloads, and other obfuscation tricks used to slip past pattern matching. Acts as a second line of defense after the deny list.",
    "claudoscope-check-public-repo.sh": "Runs before any 'git push' or PR-creation command. Checks whether the target repository is public, since forks of public repositories are themselves public by default. Catches the common mistake of accidentally pushing private code into a fork of an open-source project.",
    "claudoscope-flag-proprietary-files.sh": "Scans staged files before commits and pushes against proprietary-content patterns (strategy*, signal*, pnl*, *.key, *.pem, *.sql, etc.). Blocks accidental disclosure of business-sensitive material — a particular risk when working in a private repo that's about to become public, or in a public fork of a private codebase.",
    "claudoscope-check-package-age.sh": "Runs before package-install commands (npm install, pip install, cargo add, brew install, etc.). Blocks packages published less than 7 days ago because newly-published packages are the typical vehicle for supply-chain attacks: typosquats of popular names, malicious versions from compromised maintainer accounts, and dependency-confusion exploits.",
    "claudoscope-check-git-reset-hard.sh": "Runs before any 'git reset --hard' command. Enforces that the user's most recent message contains the literal phrase 'git reset --hard <ref>' with a specific target. Agents shouldn't be able to discard your uncommitted work because a vague instruction like 'clean up the branch' was misinterpreted.",
    "claudoscope-scan-for-credentials.sh": "Runs after every Read and Bash tool call. Scans the tool output for credential-shaped strings (API keys, AWS access keys, OAuth tokens, private keys) and redacts them before they reach the conversation. Prevents secrets from being accidentally pasted into chat history, session logs, or future context windows.",
]

/// Per-result hint that returns the entry-specific rationale when the result
/// belongs to a parameterised check (HRD002 named entry, HRD003-HRD007 named
/// hook). Falls back to the check-level hint for everything else.
func hintFor(_ result: LintResult) -> String? {
    if let subject = firstQuoted(in: result.message) {
        switch result.checkId {
        case .HRD002:
            if let rationale = hardeningDenyRuleRationale[subject] {
                return rationale
            }
        case .HRD003, .HRD004, .HRD005, .HRD006, .HRD007:
            let basename = subject.contains("/")
                ? (subject as NSString).lastPathComponent
                : subject
            if let rationale = hardeningHookRationale[basename] {
                return rationale
            }
        default:
            break
        }
    }
    return hintFor(result.checkId)
}

/// Per-row label optimized for sidebar and drift-list rendering.
///
/// When the lint message embeds a quoted subject (a deny rule, hook script
/// path, or trusted host), the subject becomes the row label so multiple
/// results for the same check are distinguishable at a glance — e.g.,
/// HRD002 rows show "Bash(rm -rf /)" / "Bash(curl * | sh)" instead of
/// 13 identical "Missing baseline deny rule" lines. Paths collapse to
/// basename so the row stays narrow. Falls back to displayNameFor for
/// checks whose message has no quoted subject (HRD001, HRD008, etc.).
func displayLabel(for result: LintResult) -> String {
    if let subject = firstQuoted(in: result.message) {
        // Only collapse to basename for genuine absolute or home-relative
        // filesystem paths. Shell-command syntax like "Bash(rm -rf /)" also
        // contains "/" but lastPathComponent on it would yield ")".
        if subject.hasPrefix("/") || subject.hasPrefix("~/") {
            return (subject as NSString).lastPathComponent
        }
        return subject
    }
    return displayNameFor(result.checkId)
}

private func firstQuoted(in text: String) -> String? {
    guard let openIdx = text.firstIndex(of: "\"") else { return nil }
    let afterOpen = text.index(after: openIdx)
    guard afterOpen < text.endIndex,
          let closeIdx = text[afterOpen...].firstIndex(of: "\"") else {
        return nil
    }
    return String(text[afterOpen..<closeIdx])
}
