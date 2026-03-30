import Foundation

enum LintSeverity: String, Sendable, CaseIterable, Comparable {
    case error
    case warning
    case info

    static func < (lhs: LintSeverity, rhs: LintSeverity) -> Bool {
        let order: [LintSeverity] = [.error, .warning, .info]
        return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
    }
}

enum LintCheckId: String, Sendable, CaseIterable {
    // CLAUDE.md checks
    case CMD001  // >200 lines
    case CMD002  // >100 lines without rules splitting
    case CMD003  // file-type patterns inline
    case CMD006  // invalid markdown (unclosed code blocks)
    case CMD_IMPORT  // @import chain >5 hops
    case CMD_DEPRECATE  // .claude/commands/ exists

    // Rules checks
    case RUL001  // malformed YAML frontmatter
    case RUL002  // invalid glob syntax in paths
    case RUL003  // glob matches no files
    case RUL005  // rule >100 lines

    // Skills checks
    case SKL001  // SKILL.md wrong casing
    case SKL002  // missing name (warning)
    case SKL003  // missing description (error)
    case SKL004  // name doesn't match directory
    case SKL005  // name not kebab-case (includes consecutive hyphens, start/end hyphen)
    case SKL006  // name >64 chars
    case SKL007  // description >1024 chars
    case SKL008  // XML angle brackets in frontmatter
    case SKL009  // reserved words in name
    case SKL012  // body >500 lines
    case SKL_AGG  // aggregate descriptions >16000 chars

    // Cross-cutting
    case XCT001  // total token estimate
    case XCT002  // tokens >5000
    case XCT003  // no .claude/ directory

    // Session checks
    case SES001  // high cost session (>$25)
    case SES002  // very long conversation (>200 messages)
    case SES003  // runaway token consumption (>2M tokens)
    case SES004  // stale session with significant history

    // Session observability checks
    case SES005  // error pattern detection (StopFailure, rate limits)
    case SES006  // idle/zombie session (>75 min gap without /clear)

    // Config health checks
    case CFG001  // sandbox.enabled without dependency lock files
    case CFG002  // allowRead/denyRead contradictory paths
    case CFG003  // ENABLE_CLAUDEAI_MCP_SERVERS=false
    case CFG004  // allowedChannelPlugins for enterprise
    case CFG005  // bare mode with hooks/MCP configured
    case CFG006  // CLAUDE_CODE_SUBPROCESS_ENV_SCRUB not set

    // Secret detection checks
    case SEC001  // private key
    case SEC002  // AWS access key
    case SEC003  // authorization header
    case SEC004  // API key/token
    case SEC005  // password/secret literal
    case SEC006  // connection string with credentials
    case SEC007  // platform token (GitHub, Slack, npm, Stripe, Google)
    case SEC008  // ENV_SCRUB not set with credential patterns in tool output
}

struct LintResult: Identifiable, Sendable {
    let id: String
    let severity: LintSeverity
    let checkId: LintCheckId
    let filePath: String
    let line: Int?
    let message: String
    let fix: String?
    let displayPath: String?
    let contextLines: [String]?
    let unmaskedSecret: String?
    let subagentFileName: String?

    init(severity: LintSeverity, checkId: LintCheckId, filePath: String, line: Int? = nil, message: String, fix: String? = nil, displayPath: String? = nil, contextLines: [String]? = nil, unmaskedSecret: String? = nil, subagentFileName: String? = nil) {
        self.id = "\(checkId.rawValue)-\(filePath)-\(subagentFileName ?? "")-\(line ?? 0)-\(message.hash)"
        self.severity = severity
        self.checkId = checkId
        self.filePath = filePath
        self.line = line
        self.message = message
        self.fix = fix
        self.displayPath = displayPath
        self.contextLines = contextLines
        self.unmaskedSecret = unmaskedSecret
        self.subagentFileName = subagentFileName
    }
}

struct LintSummary: Sendable {
    let errorCount: Int
    let warningCount: Int
    let infoCount: Int
    let healthScore: Double  // 0.0 to 1.0

    static let empty = LintSummary(errorCount: 0, warningCount: 0, infoCount: 0, healthScore: 1.0)

    static func from(results: [LintResult]) -> LintSummary {
        let errors = results.filter { $0.severity == .error }.count
        let warnings = results.filter { $0.severity == .warning }.count
        let infos = results.filter { $0.severity == .info }.count
        let total = results.count
        // Health score: errors count 3x, warnings 1x, infos 0x
        let demerits = Double(errors * 3 + warnings)
        let maxDemerits = Double(total * 3)
        let score = maxDemerits > 0 ? max(0, 1.0 - demerits / maxDemerits) : 1.0
        return LintSummary(errorCount: errors, warningCount: warnings, infoCount: infos, healthScore: score)
    }
}

struct SecretAlert: Sendable {
    let checkId: LintCheckId
    let patternName: String
    let maskedValue: String
    let sessionTitle: String
    let projectId: String
    let sessionId: String
    let isSubagent: Bool

    init(checkId: LintCheckId, patternName: String, maskedValue: String, sessionTitle: String, projectId: String, sessionId: String, isSubagent: Bool = false) {
        self.checkId = checkId
        self.patternName = patternName
        self.maskedValue = maskedValue
        self.sessionTitle = sessionTitle
        self.projectId = projectId
        self.sessionId = sessionId
        self.isSubagent = isSubagent
    }
}
