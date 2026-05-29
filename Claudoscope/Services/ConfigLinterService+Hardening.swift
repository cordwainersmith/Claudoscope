import Foundation
import CryptoKit

extension ConfigLinterService {

    // MARK: - Hardening Baseline Checks (HRD001-HRD011)

    /// Critical entries the hardening baseline expects in `permissions.deny`.
    /// Mirrors the layer1 resource so this check works even before bundle
    /// resources are wired up.
    static let hardeningDenyBaseline: [String] = [
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

    /// Hook script basenames the hardening baseline expects to find registered
    /// under PreToolUse Bash matchers in settings.json.
    static let hardeningExpectedHookBasenames: [String] = [
        "claudoscope-validate-commands.sh",
        "claudoscope-check-public-repo.sh",
        "claudoscope-flag-proprietary-files.sh",
        "claudoscope-check-package-age.sh",
        "claudoscope-check-git-reset-hard.sh"
    ]

    /// Marker bracketing the governance block in `~/.claude/CLAUDE.md`.
    static let hardeningGovernanceBeginMarker = "<!-- BEGIN: claudoscope-hardening -->"
    static let hardeningGovernanceEndMarker = "<!-- END: claudoscope-hardening -->"

    func lintHardening(globalClaudeDir: URL, projectRoot: URL?) -> [LintResult] {
        var results: [LintResult] = []

        let settingsURL = globalClaudeDir.appendingPathComponent("settings.json")
        let settingsPath = settingsURL.path
        let settingsJSON: [String: Any] = (try? Data(contentsOf: settingsURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]

        // HRD001: sandbox.enabled missing or false
        let sandboxDict = settingsJSON["sandbox"] as? [String: Any]
        let sandboxEnabled = sandboxDict?["enabled"] as? Bool ?? false
        if !sandboxEnabled {
            results.append(LintResult(
                severity: .error,
                checkId: .HRD001,
                filePath: settingsPath,
                message: "Sandbox is not enabled. Tool execution runs without filesystem or network isolation.",
                fix: "Set sandbox.enabled to true in settings.json",
                displayPath: "settings.json"
            ))
        }

        // HRD002: permissions.deny missing baseline entries
        let permissionsDict = settingsJSON["permissions"] as? [String: Any]
        let denyEntries = Set(permissionsDict?["deny"] as? [String] ?? [])
        for entry in Self.hardeningDenyBaseline where !denyEntries.contains(entry) {
            results.append(LintResult(
                severity: .warning,
                checkId: .HRD002,
                filePath: settingsPath,
                message: "Hardening baseline deny rule \"\(entry)\" is missing from permissions.deny.",
                fix: "Append \"\(entry)\" to permissions.deny in settings.json",
                displayPath: "settings.json"
            ))
        }

        // Enumerate registered hook commands by walking settings.json directly.
        // We don't go through ConfigService.loadHooks here because the linter
        // is its own actor; reading the same file the loader reads keeps this
        // sync and avoids cross-actor coupling.
        let registeredHooks = enumerateRegisteredHookCommands(in: settingsJSON)

        // HRD003: expected hardening hook not registered under any PreToolUse Bash matcher
        let registeredBasenames = Set(registeredHooks.map { ($0.command as NSString).lastPathComponent })
        for expected in Self.hardeningExpectedHookBasenames where !registeredBasenames.contains(expected) {
            results.append(LintResult(
                severity: .warning,
                checkId: .HRD003,
                filePath: settingsPath,
                message: "Expected hardening hook \"\(expected)\" is not registered under any PreToolUse Bash matcher.",
                fix: "Add a PreToolUse Bash matcher in settings.json that runs \(expected)",
                displayPath: "settings.json"
            ))
        }

        // HRD004/HRD005/HRD007: per-file checks for each registered hook command
        let fmgr = FileManager.default
        for hook in registeredHooks {
            let path = expandTilde(hook.command)
            // Only check checks for absolute-path style hook commands; skip
            // shell pipelines or commands without a leading slash.
            guard path.hasPrefix("/") else { continue }

            if !fmgr.fileExists(atPath: path) {
                // HRD004: registered file missing
                results.append(LintResult(
                    severity: .error,
                    checkId: .HRD004,
                    filePath: path,
                    message: "Registered hook command \"\(path)\" does not exist on disk.",
                    fix: "Restore the hook script or remove the entry from settings.json",
                    displayPath: relativeDisplayPath(for: path)
                ))
                continue
            }

            // File exists: check perms
            let attrs = (try? fmgr.attributesOfItem(atPath: path)) ?? [:]
            let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0

            // HRD005: owner-execute bit unset
            if perms & 0o100 == 0 {
                results.append(LintResult(
                    severity: .warning,
                    checkId: .HRD005,
                    filePath: path,
                    message: "Hook script \"\(path)\" is not executable (owner-execute bit unset).",
                    fix: "Run chmod 0755 on the script",
                    displayPath: relativeDisplayPath(for: path)
                ))
            }

            // HRD007: world-writable
            if perms & 0o002 != 0 {
                results.append(LintResult(
                    severity: .warning,
                    checkId: .HRD007,
                    filePath: path,
                    message: "Hook script \"\(path)\" is world-writable. Any local user can modify what Claude Code executes.",
                    fix: "Run chmod o-w on the script",
                    displayPath: relativeDisplayPath(for: path)
                ))
            }
        }

        // HRD006: SHA-256 drift for ~/.claude/hooks/claudoscope-*.sh
        let hooksDir = globalClaudeDir.appendingPathComponent("hooks")
        let bundledShas = loadBundledShaSidecar(name: "layer2-hooks")
        if let entries = try? fmgr.contentsOfDirectory(at: hooksDir, includingPropertiesForKeys: nil) {
            for entry in entries {
                let basename = entry.lastPathComponent
                guard basename.hasPrefix("claudoscope-"), basename.hasSuffix(".sh") else { continue }
                guard let bundled = bundledShas else { break } // sidecar missing, skip silently
                guard let expectedSha = bundled[basename] else {
                    // Local hook script we don't know about; skip silently rather than spam.
                    continue
                }
                let actualSha = sha256Hex(of: entry)
                if actualSha == nil || actualSha != expectedSha {
                    results.append(LintResult(
                        severity: .warning,
                        checkId: .HRD006,
                        filePath: entry.path,
                        message: "Hook script \"\(basename)\" SHA-256 differs from the bundled hardening baseline.",
                        fix: "Reinstall the hardening hooks to restore the trusted version",
                        displayPath: relativeDisplayPath(for: entry.path)
                    ))
                }
            }
        }

        // HRD008: autoMode key missing
        if settingsJSON["autoMode"] == nil {
            results.append(LintResult(
                severity: .info,
                checkId: .HRD008,
                filePath: settingsPath,
                message: "autoMode is not configured. Auto-mode safety policy is unset.",
                fix: "Add an autoMode block to settings.json",
                displayPath: "settings.json"
            ))
        }

        // HRD009: overly permissive entries in autoMode.environment or sandbox.network.allowedHosts
        let permissiveLiterals: Set<String> = ["*", "*.*", "https://", "http://"]
        let autoModeDict = settingsJSON["autoMode"] as? [String: Any]
        let autoModeEnv = autoModeDict?["environment"] as? [String] ?? []
        let networkDict = sandboxDict?["network"] as? [String: Any]
        let allowedHosts = networkDict?["allowedHosts"] as? [String] ?? []

        for entry in autoModeEnv where permissiveLiterals.contains(entry) {
            results.append(LintResult(
                severity: .warning,
                checkId: .HRD009,
                filePath: settingsPath,
                message: "autoMode.environment contains overly permissive entry \"\(entry)\".",
                fix: "Replace \"\(entry)\" with explicit hosts or environment names",
                displayPath: "settings.json"
            ))
        }
        for entry in allowedHosts where permissiveLiterals.contains(entry) {
            results.append(LintResult(
                severity: .warning,
                checkId: .HRD009,
                filePath: settingsPath,
                message: "sandbox.network.allowedHosts contains overly permissive entry \"\(entry)\".",
                fix: "Replace \"\(entry)\" with an explicit host allowlist",
                displayPath: "settings.json"
            ))
        }

        // HRD010: governance block in ~/.claude/CLAUDE.md
        let claudeMdURL = globalClaudeDir.appendingPathComponent("CLAUDE.md")
        let claudeMdPath = claudeMdURL.path
        if let claudeMd = try? String(contentsOf: claudeMdURL, encoding: .utf8) {
            if claudeMd.range(of: Self.hardeningGovernanceBeginMarker) == nil {
                results.append(LintResult(
                    severity: .info,
                    checkId: .HRD010,
                    filePath: claudeMdPath,
                    message: "Hardening governance block is missing from ~/.claude/CLAUDE.md.",
                    fix: "Install the hardening baseline to add the governance block",
                    displayPath: "CLAUDE.md"
                ))
            } else if let extractedBody = extractGovernanceBlock(from: claudeMd),
                      let bundledURL = Bundle.main.url(
                          forResource: "layer4-governance",
                          withExtension: "md",
                          subdirectory: "HardeningBaseline"
                      ),
                      let bundledText = try? String(contentsOf: bundledURL, encoding: .utf8) {
                let bundledHash = sha256Hex(of: bundledText.trimmingCharacters(in: .newlines))
                let actualHash = sha256Hex(of: extractedBody)
                if actualHash != bundledHash {
                    results.append(LintResult(
                        severity: .warning,
                        checkId: .HRD010,
                        filePath: claudeMdPath,
                        message: "Hardening governance block in ~/.claude/CLAUDE.md has drifted from the bundled baseline.",
                        fix: "Reinstall the hardening baseline to refresh the governance block",
                        displayPath: "CLAUDE.md"
                    ))
                }
            }
        } else {
            results.append(LintResult(
                severity: .info,
                checkId: .HRD010,
                filePath: claudeMdPath,
                message: "~/.claude/CLAUDE.md does not exist, so the hardening governance block is not present.",
                fix: "Install the hardening baseline to create the governance block",
                displayPath: "CLAUDE.md"
            ))
        }

        // HRD012: autoMode present but hard_deny is missing or empty
        if let autoModeDict = settingsJSON["autoMode"] as? [String: Any] {
            let hardDeny = autoModeDict["hard_deny"] as? [String] ?? []
            if hardDeny.isEmpty {
                results.append(LintResult(
                    severity: .warning,
                    checkId: .HRD012,
                    filePath: settingsPath,
                    message: "autoMode is configured but hard_deny is missing or empty. Auto-mode tool blocking is not enforced.",
                    fix: "Add at least one entry to autoMode.hard_deny in settings.json",
                    displayPath: "settings.json"
                ))
            }
        }

        // HRD011: security awareness skill
        let skillURL = globalClaudeDir
            .appendingPathComponent("skills")
            .appendingPathComponent("claudoscope-security-awareness.md")
        let skillPath = skillURL.path
        if !fmgr.fileExists(atPath: skillPath) {
            results.append(LintResult(
                severity: .warning,
                checkId: .HRD011,
                filePath: skillPath,
                message: "Security awareness skill is not installed at ~/.claude/skills/claudoscope-security-awareness.md.",
                fix: "Install the hardening baseline to deploy the security awareness skill",
                displayPath: "skills/claudoscope-security-awareness.md"
            ))
        } else if let bundledShaMap = loadBundledShaSidecar(
            name: "claudoscope-security-awareness",
            subdirectory: "HardeningBaseline/skills"
        ),
        let expectedSha = bundledShaMap["claudoscope-security-awareness.md"] ?? bundledShaMap.values.first {
            let actualSha = sha256Hex(of: skillURL)
            if actualSha == nil || actualSha != expectedSha {
                results.append(LintResult(
                    severity: .warning,
                    checkId: .HRD011,
                    filePath: skillPath,
                    message: "Security awareness skill has drifted from the bundled baseline.",
                    fix: "Reinstall the hardening baseline to refresh the skill",
                    displayPath: "skills/claudoscope-security-awareness.md"
                ))
            }
        }

        return results
    }

    // MARK: - Hardening Helpers

    /// Walks the `hooks` block of a settings dict and returns every hook
    /// command registered under any event/matcher.
    private func enumerateRegisteredHookCommands(in settings: [String: Any]) -> [HookCommand] {
        guard let hooksDict = settings["hooks"] as? [String: Any] else { return [] }
        var out: [HookCommand] = []
        for (_, value) in hooksDict {
            guard let rulesArray = value as? [[String: Any]] else { continue }
            for ruleDict in rulesArray {
                guard let hooksArray = ruleDict["hooks"] as? [[String: Any]] else { continue }
                for hookDict in hooksArray {
                    out.append(HookCommand(
                        type: hookDict["type"] as? String,
                        command: hookDict["command"] as? String ?? "",
                        timeout: hookDict["timeout"] as? Int
                    ))
                }
            }
        }
        return out
    }

    private func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        return (path as NSString).expandingTildeInPath
    }

    private func relativeDisplayPath(for absolute: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if absolute.hasPrefix(home) {
            return "~" + String(absolute.dropFirst(home.count))
        }
        return (absolute as NSString).lastPathComponent
    }

    private func sha256Hex(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func sha256Hex(of string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Loads a `*.sha256` sidecar from the bundle, parsing lines like
    /// `<hex>  <basename>` (the canonical `sha256sum` output format).
    private func loadBundledShaSidecar(name: String, subdirectory: String = "HardeningBaseline") -> [String: String]? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "sha256", subdirectory: subdirectory),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }

        var map: [String: String] = [:]
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            // Split on whitespace; first field is hex digest, last field is filename.
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2 else { continue }
            let hex = String(parts[0])
            let filename = String(parts.last!).trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            map[(filename as NSString).lastPathComponent] = hex
        }
        return map.isEmpty ? nil : map
    }

    /// Returns the SHA-256 hex of a bundled file, computed at runtime so we
    /// don't need a sidecar for single-file resources.
    /// Returns the body between the BEGIN/END governance markers (markers
    /// excluded), trimmed of surrounding newlines so the byte content is
    /// directly comparable to the bundled `layer4-governance.md`. Returns nil
    /// if either marker is missing or out of order.
    private func extractGovernanceBlock(from text: String) -> String? {
        guard let beginRange = text.range(of: Self.hardeningGovernanceBeginMarker) else {
            return nil
        }
        guard let endRange = text.range(
            of: Self.hardeningGovernanceEndMarker,
            range: beginRange.upperBound..<text.endIndex
        ) else {
            return nil
        }
        let body = String(text[beginRange.upperBound..<endRange.lowerBound])
        return body.trimmingCharacters(in: .newlines)
    }
}
