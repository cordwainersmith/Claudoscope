import Foundation

extension ConfigService {
    /// Discover hooks dicts contributed by installed plugins.
    /// Returns one entry per plugin that has any hooks defined, in the shape the
    /// settings.json `hooks` value would take (event name -> array of rule dicts).
    ///
    /// Probes three documented manifest layouts in priority order, taking the first match:
    ///   (a) `<versionDir>/hooks/hooks.json` — canonical separate file
    ///   (b) `<versionDir>/.claude-plugin/plugin.json` with a `hooks` field
    ///   (c) `<versionDir>/plugin.json` with a `hooks` field
    ///
    /// In layouts (b) and (c), the `hooks` field may be:
    ///   - an inline object,
    ///   - a string path to a hooks JSON file (relative to the plugin root),
    ///   - an array of such path strings whose event lists are merged.
    func pluginHookDicts() -> [(pluginName: String, hooksDict: [String: Any])] {
        var out: [(String, [String: Any])] = []

        for (plugin, versionDir) in latestPluginVersionDirs() {
            // (a) hooks/hooks.json — the file itself IS the hooks dict.
            let canonicalURL = versionDir
                .appendingPathComponent("hooks")
                .appendingPathComponent("hooks.json")
            if let dict = readJSON(at: canonicalURL) {
                out.append((plugin, dict))
                continue
            }

            // (b) .claude-plugin/plugin.json
            let nestedManifest = versionDir
                .appendingPathComponent(".claude-plugin")
                .appendingPathComponent("plugin.json")
            if let manifest = readJSON(at: nestedManifest),
               let hooks = extractHooksDict(from: manifest, pluginRoot: versionDir) {
                out.append((plugin, hooks))
                continue
            }

            // (c) plugin.json at the version dir root (e.g. pyright)
            let flatManifest = versionDir.appendingPathComponent("plugin.json")
            if let manifest = readJSON(at: flatManifest),
               let hooks = extractHooksDict(from: manifest, pluginRoot: versionDir) {
                out.append((plugin, hooks))
            }
        }

        return out
    }

    // MARK: - Plugin inventory

    /// Build the full plugin inventory from the on-disk cache, populated with the
    /// components each plugin contributes and any dependencies it declares.
    ///
    /// Enabled state comes from settings.json (`enabledPlugins` map + `skippedPlugins`
    /// list), keyed by `name@marketplace`. A plugin present on disk but absent from
    /// both lists is treated as enabled (Claude Code's default once a manifest is cached).
    ///
    /// `components` is taken from the manifest's explicit `components` array when
    /// present, otherwise derived by probing the documented component directories
    /// (`commands/`, `skills/`, `agents/`) and manifest files (`hooks/hooks.json`,
    /// `.mcp.json`). `dependencies` is read from the manifest's `dependencies` field
    /// (array of `name` or `name@marketplace` strings); nil when not declared.
    func loadPlugins() -> [PluginInfo] {
        let settings = readJSON(at: claudeDir.appendingPathComponent("settings.json")) ?? [:]
        let enabledMap = settings["enabledPlugins"] as? [String: Any] ?? [:]
        let skipped = Set(settings["skippedPlugins"] as? [String] ?? [])

        var plugins: [PluginInfo] = []

        for (pluginDirName, versionDir) in latestPluginVersionDirs() {
            // versionDir = .../cache/<marketplace>/<plugin>/<version>
            let marketplace = versionDir
                .deletingLastPathComponent()      // .../<plugin>
                .deletingLastPathComponent()      // .../<marketplace>
                .lastPathComponent

            let manifest = readPluginManifest(in: versionDir)
            let name = (manifest?["name"] as? String) ?? pluginDirName
            let fullName = "\(name)@\(marketplace)"

            let enabled: Bool
            if skipped.contains(fullName) {
                enabled = false
            } else if let value = enabledMap[fullName] {
                enabled = (value as? NSNumber)?.boolValue ?? true
            } else {
                enabled = true
            }

            let dependencies = parseStringList(manifest?["dependencies"])
            let components = pluginComponents(manifest: manifest, versionDir: versionDir)
            let componentsByKind = pluginComponentNames(versionDir: versionDir)

            plugins.append(PluginInfo(
                fullName: fullName,
                name: name,
                marketplace: marketplace,
                enabled: enabled,
                components: components,
                dependencies: dependencies,
                componentsByKind: componentsByKind
            ))
        }

        plugins.sort { $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending }
        return plugins
    }

    /// Read a plugin's manifest, probing the nested `.claude-plugin/plugin.json`
    /// location first, then the flat `plugin.json` at the version-dir root.
    private func readPluginManifest(in versionDir: URL) -> [String: Any]? {
        let nested = versionDir
            .appendingPathComponent(".claude-plugin")
            .appendingPathComponent("plugin.json")
        if let manifest = readJSON(at: nested) { return manifest }

        let flat = versionDir.appendingPathComponent("plugin.json")
        return readJSON(at: flat)
    }

    /// The components a plugin contributes. Prefers an explicit manifest
    /// `components` array; otherwise probes the documented directories and files.
    /// Each entry is a short label like "skills (22)" or "mcp".
    private func pluginComponents(manifest: [String: Any]?, versionDir: URL) -> [String] {
        if let declared = parseStringList(manifest?["components"]), !declared.isEmpty {
            return declared
        }

        var components: [String] = []
        for dir in ["commands", "skills", "agents"] {
            let count = directoryEntryCount(versionDir.appendingPathComponent(dir))
            if count > 0 { components.append("\(dir) (\(count))") }
        }
        if fm.fileExists(atPath: versionDir.appendingPathComponent("hooks").appendingPathComponent("hooks.json").path) {
            components.append("hooks")
        }
        if fm.fileExists(atPath: versionDir.appendingPathComponent(".mcp.json").path) {
            components.append("mcp")
        }
        return components
    }

    private func directoryEntryCount(_ url: URL) -> Int {
        guard let entries = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        return entries.count
    }

    /// Entry names a plugin contributes per kind (commands/skills/agents), for
    /// drill-down. Skills are directories (name = dir name); commands/agents are
    /// `.md` files (name = filename without extension). Returns nil if none.
    private func pluginComponentNames(versionDir: URL) -> [String: [String]]? {
        var byKind: [String: [String]] = [:]
        for dir in ["commands", "skills", "agents"] {
            let names = directoryEntryNames(versionDir.appendingPathComponent(dir))
            if !names.isEmpty { byKind[dir] = names }
        }
        return byKind.isEmpty ? nil : byKind
    }

    private func directoryEntryNames(_ url: URL) -> [String] {
        guard let entries = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .map { $0.pathExtension == "md" ? $0.deletingPathExtension().lastPathComponent : $0.lastPathComponent }
            .sorted()
    }

    /// Coerce a manifest field into a `[String]`. Accepts a JSON array of strings,
    /// or an array of `{"name": "..."}` / `{"plugin": "..."}` dicts (the documented
    /// dependency shapes). Returns nil when the field is absent or empty.
    private func parseStringList(_ value: Any?) -> [String]? {
        guard let raw = value as? [Any] else { return nil }
        let strings: [String] = raw.compactMap { entry in
            if let s = entry as? String { return s }
            if let dict = entry as? [String: Any] {
                return (dict["name"] as? String) ?? (dict["plugin"] as? String)
            }
            return nil
        }
        return strings.isEmpty ? nil : strings
    }

    private func extractHooksDict(from manifest: [String: Any], pluginRoot: URL) -> [String: Any]? {
        guard let raw = manifest["hooks"] else { return nil }

        if let inline = raw as? [String: Any] {
            return inline
        }
        if let pathStr = raw as? String {
            return readJSON(at: pluginRoot.appendingPathComponent(pathStr))
        }
        if let paths = raw as? [String] {
            var merged: [String: Any] = [:]
            for path in paths {
                guard let dict = readJSON(at: pluginRoot.appendingPathComponent(path)) else { continue }
                for (event, rules) in dict {
                    if var existing = merged[event] as? [Any], let new = rules as? [Any] {
                        existing.append(contentsOf: new)
                        merged[event] = existing
                    } else {
                        merged[event] = rules
                    }
                }
            }
            return merged.isEmpty ? nil : merged
        }
        return nil
    }
}
