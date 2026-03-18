import Foundation

extension ConfigLinterService {

    // MARK: - Secret Detection

    struct SecretPattern {
        let checkId: LintCheckId
        let name: String
        let regex: NSRegularExpression
        let severity: LintSeverity
        let skipHosts: [String]?
        let secretGroup: Int?
        let entropyThreshold: Double?
        let requiresDigit: Bool

        init(checkId: LintCheckId, name: String, pattern: String, severity: LintSeverity,
             skipHosts: [String]? = nil, secretGroup: Int? = nil,
             entropyThreshold: Double? = nil, requiresDigit: Bool = false,
             caseInsensitive: Bool = false) {
            self.checkId = checkId
            self.name = name
            var opts: NSRegularExpression.Options = []
            if caseInsensitive { opts.insert(.caseInsensitive) }
            self.regex = try! NSRegularExpression(pattern: pattern, options: opts)
            self.severity = severity
            self.skipHosts = skipHosts
            self.secretGroup = secretGroup
            self.entropyThreshold = entropyThreshold
            self.requiresDigit = requiresDigit
        }
    }

    static let secretPatterns: [SecretPattern] = [
        SecretPattern(
            checkId: .SEC001, name: "Private Key",
            pattern: "-----BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----",
            severity: .error
        ),
        SecretPattern(
            checkId: .SEC002, name: "AWS Access Key",
            pattern: "(AKIA|ASIA)[A-Z0-9]{16}",
            severity: .error,
            entropyThreshold: 3.0
        ),
        SecretPattern(
            checkId: .SEC003, name: "Authorization Header",
            pattern: "Authorization.*?(Bearer|Basic)\\s+([A-Za-z0-9+/=._-]{20,})",
            severity: .warning,
            secretGroup: 2, entropyThreshold: 3.5, requiresDigit: true
        ),
        SecretPattern(
            checkId: .SEC004, name: "API Key/Token",
            pattern: "(api[_-]?key|api[_-]?token|access[_-]?token)\\s*[:=]\\s*[\"']?([A-Za-z0-9_\\-./+=]{20,})",
            severity: .warning,
            secretGroup: 2, entropyThreshold: 3.5, requiresDigit: true,
            caseInsensitive: true
        ),
        SecretPattern(
            checkId: .SEC005, name: "Password/Secret Literal",
            pattern: "(password|passwd|secret)\\s*[:=]\\s*[\"']([^\"']{12,})[\"']",
            severity: .warning,
            secretGroup: 2, entropyThreshold: 3.0, requiresDigit: true,
            caseInsensitive: true
        ),
        SecretPattern(
            checkId: .SEC006, name: "Connection String",
            pattern: "(mongodb|postgres|mysql|redis|jdbc)[+a-z]*://[^:]+:([^@]+)@",
            severity: .warning,
            skipHosts: ["localhost", "127.0.0.1", "0.0.0.0", "host.docker.internal", "example.com", "db", "database"],
            secretGroup: 2, entropyThreshold: 2.5
        ),
        SecretPattern(
            checkId: .SEC007, name: "Platform Token",
            pattern: "(ghp_[A-Za-z0-9_]{36}|github_pat_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{20,}|xox[bps]-[A-Za-z0-9./-]{20,}|npm_[A-Za-z0-9]{36}|sk_live_[A-Za-z0-9]{20,}|AIza[A-Za-z0-9_-]{35})",
            severity: .warning
        ),
    ]

    static let falsePositiveSubstrings: [String] = [
        "AKIAIOSFODNN7EXAMPLE", "sk_test_", "pk_test_", "your-api-key",
        "<your-", "placeholder", "changeme", "example", "TODO", "xxxxxxxx",
        "0000000000", "abcdefgh", "REPLACE_ME",
        "XXX", "xxx", "REDACTED", "MASKED", "DUMMY", "FAKE", "NONE",
        "null", "undefined", "N/A", "INSERT_", "PASTE_",
        "${", "{{", "<your", "%s", "{0}"
    ]

    static let conversationalContextPhrases: [String] = [
        "in the .env", "set your", "configure the", "stored in",
        "replace with", "environment variable", "add to your",
        "put your", ".env file"
    ]

    static func shannonEntropy(_ s: String) -> Double {
        guard !s.isEmpty else { return 0.0 }
        var freq: [Character: Int] = [:]
        for c in s { freq[c, default: 0] += 1 }
        let length = Double(s.count)
        var entropy = 0.0
        for count in freq.values {
            let p = Double(count) / length
            entropy -= p * log2(p)
        }
        return entropy
    }

    static func maskSecret(_ value: String) -> String {
        guard value.count >= 8 else { return "****" }
        let prefix = String(value.prefix(4))
        let suffix = String(value.suffix(4))
        return "\(prefix)****\(suffix)"
    }

    /// Truncate and clean a JSONL line for display as context
    static func sanitizeContextLine(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 200 { return trimmed }
        return String(trimmed.prefix(200)) + "..."
    }

    struct SecretFinding: Sendable {
        let checkId: LintCheckId
        let patternName: String
        let matchedText: String
        let lineIndex: Int?
    }

    func scanLinesForSecrets(_ lines: [String]) -> [SecretFinding] {
        var findings: [SecretFinding] = []
        for (lineIndex, line) in lines.enumerated() {
            guard line.count <= 200_000 else { continue }
            let nsLine = line as NSString
            let range = NSRange(location: 0, length: nsLine.length)

            for pattern in Self.secretPatterns {
                guard let match = pattern.regex.firstMatch(in: line, options: [], range: range) else { continue }
                let matchedText = nsLine.substring(with: match.range)

                // 1. Extract the secret value via capture group (or full match)
                let secretValue: String
                if let group = pattern.secretGroup,
                   group < match.numberOfRanges,
                   match.range(at: group).location != NSNotFound {
                    secretValue = nsLine.substring(with: match.range(at: group))
                } else {
                    secretValue = matchedText
                }

                let lowerValue = secretValue.lowercased()
                let lowerLine = line.lowercased()

                // 2. Check false positive substrings against value and full line
                if Self.falsePositiveSubstrings.contains(where: { lowerValue.contains($0.lowercased()) || lowerLine.contains($0.lowercased()) }) {
                    continue
                }

                // 3. Check conversational context phrases against full line
                if Self.conversationalContextPhrases.contains(where: { lowerLine.contains($0.lowercased()) }) {
                    continue
                }

                // 4. Check unique character count (<= 3 unique chars -> skip)
                let uniqueChars = Set(secretValue)
                if uniqueChars.count <= 3 {
                    continue
                }

                // 5. Check hasDigit requirement (SEC003/004/005)
                if pattern.requiresDigit && !secretValue.contains(where: { $0.isNumber }) {
                    continue
                }

                // 6. Shannon entropy check
                if let threshold = pattern.entropyThreshold {
                    let entropy = Self.shannonEntropy(secretValue)
                    if entropy < threshold {
                        continue
                    }
                }

                // 7. SEC006: skip local/example hosts
                if let skipHosts = pattern.skipHosts {
                    if skipHosts.contains(where: { lowerLine.contains($0) }) {
                        continue
                    }
                }

                findings.append(SecretFinding(
                    checkId: pattern.checkId,
                    patternName: pattern.name,
                    matchedText: matchedText,
                    lineIndex: lineIndex
                ))
            }
        }
        return findings
    }

    static let secMaxPerPatternPerFile = 3
    static let secMaxTotal = 20
    static let secLookbackDays = 30
    static let secMinMessages = 10

    func lintSessionSecrets(_ sessions: [SessionSummary], claudeDir: URL) -> [LintResult] {
        let now = Date()
        let calendar = Calendar.current
        let cutoff = calendar.date(byAdding: .day, value: -Self.secLookbackDays, to: now)!

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFormatterNoFrac = ISO8601DateFormatter()
        isoFormatterNoFrac.formatOptions = [.withInternetDateTime]

        func parseDate(_ str: String) -> Date? {
            isoFormatter.date(from: str) ?? isoFormatterNoFrac.date(from: str)
        }

        var results: [LintResult] = []

        for session in sessions {
            guard session.messageCount > Self.secMinMessages else { continue }
            guard let firstDate = parseDate(session.firstTimestamp), firstDate >= cutoff else { continue }

            // Build file paths for this session
            let projectDir = claudeDir
                .appendingPathComponent("projects")
                .appendingPathComponent(session.projectId)
            let mainFile = projectDir.appendingPathComponent("\(session.id).jsonl")

            var filesToScan: [URL] = []
            if fm.fileExists(atPath: mainFile.path) {
                filesToScan.append(mainFile)
            }

            // Check for subagent files
            let subagentDir = projectDir
                .appendingPathComponent(session.id)
                .appendingPathComponent("subagents")
            if let subagentFiles = try? fm.contentsOfDirectory(at: subagentDir, includingPropertiesForKeys: nil) {
                for file in subagentFiles where file.pathExtension == "jsonl" {
                    filesToScan.append(file)
                }
            }

            let syntheticPath = "sessions/\(session.projectId)/\(session.id)"
            let displayTitle = String(session.title.prefix(60))

            // Track per-pattern counts for this session's files
            var patternCounts: [LintCheckId: Int] = [:]

            for fileURL in filesToScan {
                guard let data = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
                let lines = data.components(separatedBy: "\n")
                let isSubagent = fileURL != mainFile

                let findings = scanLinesForSecrets(lines)
                for finding in findings {
                    let count = patternCounts[finding.checkId, default: 0]
                    guard count < Self.secMaxPerPatternPerFile else { continue }
                    guard results.count < Self.secMaxTotal else { return results }

                    patternCounts[finding.checkId] = count + 1
                    let masked = Self.maskSecret(finding.matchedText)

                    // Capture context: the line before and the line containing the secret
                    var context: [String] = []
                    if let idx = finding.lineIndex {
                        if idx > 0 {
                            context.append(Self.sanitizeContextLine(lines[idx - 1]))
                        }
                        context.append(Self.sanitizeContextLine(lines[idx]))
                    }

                    results.append(LintResult(
                        severity: Self.secretPatterns.first(where: { $0.checkId == finding.checkId })?.severity ?? .warning,
                        checkId: finding.checkId,
                        filePath: syntheticPath,
                        message: "\(finding.patternName) detected: \(masked)",
                        fix: "Rotate this credential immediately. Avoid pasting secrets into Claude Code sessions. Use environment variables or secret managers instead.",
                        displayPath: displayTitle,
                        contextLines: context.isEmpty ? nil : context,
                        unmaskedSecret: finding.matchedText,
                        subagentFileName: isSubagent ? fileURL.lastPathComponent : nil
                    ))
                }
            }

            if results.count >= Self.secMaxTotal { break }
        }

        results.sort { $0.severity < $1.severity }
        return results
    }
}
