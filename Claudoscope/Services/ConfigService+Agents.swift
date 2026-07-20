import Foundation

extension ConfigService {
    /// Scan agent definitions from plugins, ~/.claude/agents/, and each project's
    /// .claude/agents/. Project ids (not paths) are passed in because `Project.path`
    /// is the encoded session dir, not the working tree — the real repo path is
    /// recovered via `decodeProjectPath`, the same pattern `detectCanonProjects` uses.
    func loadAgents(projectIds: [String]) -> [AgentEntry] {
        var entries: [AgentEntry] = []

        // 1. Plugin agents from ~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/agents/
        for (plugin, versionDir) in latestPluginVersionDirs() {
            entries += readAgentDir(versionDir.appendingPathComponent("agents"),
                                    source: .plugin(name: plugin))
        }

        // 2. User agents from ~/.claude/agents/
        entries += readAgentDir(claudeDir.appendingPathComponent("agents"), source: .user)

        // 3. Project agents from <realRepoPath>/.claude/agents/
        for id in projectIds {
            guard let path = decodeProjectPath(id) else { continue }
            let repo = URL(fileURLWithPath: path)
            let dir = repo.appendingPathComponent(".claude").appendingPathComponent("agents")
            entries += readAgentDir(dir, source: .project(name: repo.lastPathComponent))
        }

        // Routing agents first (canonical order), then the rest alphabetically.
        return entries.sorted { a, b in
            switch (a.isRoutingAgent, b.isRoutingAgent) {
            case (true, true):
                let ia = AgentEntry.routingOrder.firstIndex(of: a.name.lowercased()) ?? .max
                let ib = AgentEntry.routingOrder.firstIndex(of: b.name.lowercased()) ?? .max
                return ia < ib
            case (true, false): return true
            case (false, true): return false
            case (false, false):
                return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
            }
        }
    }

    private func readAgentDir(_ dir: URL, source: AgentSource) -> [AgentEntry] {
        guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        return files.filter { $0.hasSuffix(".md") }.compactMap { file in
            readAgentFile(url: dir.appendingPathComponent(file),
                          name: String(file.dropLast(3)), source: source)
        }
    }

    func readAgentFile(url: URL, name: String, source: AgentSource) -> AgentEntry? {
        guard fm.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let sizeBytes = (attrs?[.size] as? Int) ?? data.count
        let parsed = parseFrontmatter(content)
        let resolvedName = parsed.name ?? name

        // Normalize list-valued fields to comma-joined strings. Agents use
        // `tools:`, `disallowedTools:` (camelCase), and `skills:`. The
        // tool-restrictions view reads `disallowed-tools`, so remap the key.
        var meta = parsed.metadata
        if let raw = meta["tools"] { meta["tools"] = parseToolList(raw)?.joined(separator: ", ") }
        if let raw = meta["skills"] { meta["skills"] = parseToolList(raw)?.joined(separator: ", ") }
        if let raw = meta.removeValue(forKey: "disallowedTools") {
            meta["disallowed-tools"] = parseToolList(raw)?.joined(separator: ", ")
        }

        let displayName: String
        switch source {
        case .user:           displayName = resolvedName
        case .plugin(let n):  displayName = "\(resolvedName) (\(n))"
        case .project(let n): displayName = "\(resolvedName) (\(n))"
        }

        return AgentEntry(
            name: resolvedName,
            displayName: displayName,
            description: parsed.description,
            metadata: meta,
            body: parsed.body,
            sizeBytes: sizeBytes,
            source: source
        )
    }
}
