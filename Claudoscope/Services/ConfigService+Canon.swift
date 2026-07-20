import Foundation

extension ConfigService {
    // MARK: - Canon

    /// Load a project's canon records + install status off disk. Reads the repo
    /// working tree (`<projectPath>/.claude/`), not `~/.claude/`, resolving the
    /// path via `decodeProjectPath` (shared with the memory loader).
    func loadCanon(projectId: String?) -> CanonData {
        guard let projectId, let projectPath = decodeProjectPath(projectId) else {
            return CanonData(
                projectId: projectId, records: [], rawExists: false,
                protocolInstalled: false, protocolVersion: nil,
                recordsGitignored: nil, dataPath: nil, rulePath: nil
            )
        }

        let projectClaude = URL(fileURLWithPath: projectPath).appendingPathComponent(".claude")
        let dataURL = projectClaude.appendingPathComponent(CanonArtifacts.dataRelativePath)
        let ruleURL = projectClaude.appendingPathComponent(CanonArtifacts.ruleRelativePath)

        let rawExists = fm.fileExists(atPath: dataURL.path)
        let dataText = (try? String(contentsOf: dataURL, encoding: .utf8)) ?? ""
        let records = CanonParsing.parseCanonRecords(dataText)

        let protocolInstalled = fm.fileExists(atPath: ruleURL.path)
        let ruleText = protocolInstalled ? (try? String(contentsOf: ruleURL, encoding: .utf8)) : nil
        let version = ruleText.flatMap { CanonParsing.parseProtocolVersion($0) }

        let gitignored = rawExists
            ? CanonGit.isPathGitignored(projectRoot: projectPath, path: dataURL.path)
            : nil

        return CanonData(
            projectId: projectId,
            records: records,
            rawExists: rawExists,
            protocolInstalled: protocolInstalled,
            protocolVersion: version,
            recordsGitignored: gitignored,
            dataPath: dataURL.path,
            rulePath: ruleURL.path
        )
    }

    /// Ids of projects that have canon artifacts on disk (records file or
    /// protocol rule). Powers the sidebar "detected on disk" indicator so a
    /// teammate's committed canon is discoverable even before local opt-in.
    /// Resolves each id to its real repo path (Project.path is the session dir,
    /// not the working tree) via `decodeProjectPath`.
    func detectCanonProjects(projectIds: [String]) -> Set<String> {
        var detected: Set<String> = []
        for id in projectIds {
            guard let path = decodeProjectPath(id) else { continue }
            let claude = URL(fileURLWithPath: path).appendingPathComponent(".claude")
            let data = claude.appendingPathComponent(CanonArtifacts.dataRelativePath)
            let rule = claude.appendingPathComponent(CanonArtifacts.ruleRelativePath)
            if fm.fileExists(atPath: data.path) || fm.fileExists(atPath: rule.path) {
                detected.insert(id)
            }
        }
        return detected
    }

    /// Resolve a project id to its real repo working-tree path (nil if the
    /// directory no longer exists on disk). Thin wrapper so the store can resolve
    /// paths for canon install/uninstall without reaching into the memory loader.
    func realProjectPath(_ projectId: String) -> String? {
        decodeProjectPath(projectId)
    }

    /// Classify every project id for canon install eligibility, resolved against
    /// the full set (an id is a "container" only relative to the others). Decodes
    /// each id once; ids that no longer resolve on disk map to `.directoryMissing`.
    /// See `CanonEligibility` for the rules.
    func canonClassifications(_ projectIds: [String]) -> [String: CanonTargetKind] {
        var dirById: [String: String] = [:]
        for id in projectIds {
            if let dir = decodeProjectPath(id) { dirById[id] = dir }
        }
        let allDirs = Array(dirById.values)
        let exists: (String) -> Bool = { self.fm.fileExists(atPath: $0) }

        var out: [String: CanonTargetKind] = [:]
        for id in projectIds {
            guard let dir = dirById[id] else { out[id] = .directoryMissing; continue }
            out[id] = CanonEligibility.classify(dir: dir, allDirs: allDirs, fileExists: exists)
        }
        return out
    }

    /// Canon classification for a single project id, resolved against the full set.
    func classifyCanonTarget(_ projectId: String, allProjectIds: [String]) -> CanonTargetKind {
        canonClassifications(allProjectIds)[projectId] ?? .directoryMissing
    }
}
