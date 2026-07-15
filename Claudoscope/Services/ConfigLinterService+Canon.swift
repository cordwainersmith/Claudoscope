import Foundation

extension ConfigLinterService {
    // MARK: - Canon (CAN family)

    /// Lint a project's canon artifacts. Only called by the store for opted-in
    /// projects. Reuses the pure `CanonParsing` checks so findings can't drift
    /// from the Canon rail's self-computed banner.
    func lintCanon(projectRoot: String, bundledProtocolVersion: Int) -> [LintResult] {
        var results: [LintResult] = []

        let projectClaude = URL(fileURLWithPath: projectRoot).appendingPathComponent(".claude")
        let ruleURL = projectClaude.appendingPathComponent(CanonArtifacts.ruleRelativePath)
        let dataURL = projectClaude.appendingPathComponent(CanonArtifacts.dataRelativePath)

        // CAN001: opted-in but protocol rule missing.
        if !fm.fileExists(atPath: ruleURL.path) {
            results.append(LintResult(
                severity: .error,
                checkId: .CAN001,
                filePath: ruleURL.path,
                message: "Canon is enabled for this project but the protocol rule .claude/rules/canon.md is missing, so Claude Code won't follow the canon protocol.",
                fix: "Re-enable Canon from the Canon rail to reinstall the protocol rule.",
                displayPath: ".claude/rules/canon.md"
            ))
        } else {
            // CAN004: installed protocol older than what this build ships.
            let ruleText = (try? String(contentsOf: ruleURL, encoding: .utf8)) ?? ""
            let installed = CanonParsing.parseProtocolVersion(ruleText)
            if (installed ?? 0) < bundledProtocolVersion {
                let installedLabel = installed.map(String.init) ?? "unknown"
                results.append(LintResult(
                    severity: .info,
                    checkId: .CAN004,
                    filePath: ruleURL.path,
                    message: "Canon protocol is v\(installedLabel); this app bundles v\(bundledProtocolVersion).",
                    fix: "Reinstall Canon from the Canon rail to update the protocol rule.",
                    displayPath: ".claude/rules/canon.md"
                ))
            }
        }

        // Parse records once for CAN003 + CAN005.
        let dataText = (try? String(contentsOf: dataURL, encoding: .utf8)) ?? ""
        let records = CanonParsing.parseCanonRecords(dataText)

        for rec in CanonParsing.malformedRecords(records) {
            results.append(LintResult(
                severity: .warning,
                checkId: .CAN003,
                filePath: dataURL.path,
                message: "Canon record \"\(rec.title)\" is malformed: missing or invalid metadata line.",
                fix: "Fix the metadata line: `kind: <choice|constraint|convention|gotcha> | date: YYYY-MM-DD | status: canon`.",
                displayPath: ".claude/canon.md"
            ))
        }

        for (rec, missing) in CanonParsing.danglingSupersedes(records) {
            let message: String
            if let missing {
                message = "Canon record \"\(rec.title)\" is superseded by \"\(missing)\", which doesn't exist."
            } else {
                message = "Canon record \"\(rec.title)\" is marked non-canon but has no `superseded by:` pointer."
            }
            results.append(LintResult(
                severity: .info,
                checkId: .CAN005,
                filePath: dataURL.path,
                message: message,
                fix: "Point the status to an existing record title, or restore it to `status: canon`.",
                displayPath: ".claude/canon.md"
            ))
        }

        // CAN002: records exist but are gitignored, so they won't be shared.
        if fm.fileExists(atPath: dataURL.path),
           CanonGit.isPathGitignored(projectRoot: projectRoot, path: dataURL.path) == true {
            results.append(LintResult(
                severity: .warning,
                checkId: .CAN002,
                filePath: dataURL.path,
                message: "Canon records (.claude/canon.md) are gitignored, so committed decisions won't be shared with your team.",
                fix: "Un-ignore the canon files in .gitignore:\n!.claude/\n!.claude/canon.md\n!.claude/rules/\n!.claude/rules/canon.md",
                displayPath: ".claude/canon.md"
            ))
        }

        return results
    }
}
