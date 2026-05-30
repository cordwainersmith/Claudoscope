import Foundation

extension ConfigLinterService {

    // MARK: - Plugin Checks (PLG001-PLG003)

    /// Lint the installed plugin inventory.
    ///
    /// - PLG001: a plugin declares a dependency that is not satisfied by an
    ///   installed *and* enabled plugin (matched by bare name or `name@marketplace`).
    /// - PLG002: the dependency graph contains a cycle. Every plugin that
    ///   participates in a cycle gets one result.
    /// - PLG003: a plugin contributes no components (commands/skills/hooks/etc.).
    ///
    /// Subject names are quoted in messages so the Config Health UI can surface
    /// them per-row (see `displayLabel(for:)`).
    func lintPlugins(plugins: [PluginInfo]) -> [LintResult] {
        guard !plugins.isEmpty else { return [] }

        var results: [LintResult] = []

        // Resolution index: a declared dependency string may be a bare name or a
        // full `name@marketplace`. Map both forms to the owning plugin so lookups
        // are O(1). Bare-name collisions across marketplaces are rare; last write
        // wins, which is acceptable for a satisfied/unsatisfied check.
        var byName: [String: PluginInfo] = [:]
        var byFullName: [String: PluginInfo] = [:]
        for plugin in plugins {
            byName[plugin.name] = plugin
            byFullName[plugin.fullName] = plugin
        }

        func resolve(_ dependency: String) -> PluginInfo? {
            byFullName[dependency] ?? byName[dependency]
        }

        // PLG001: unsatisfied dependencies
        for plugin in plugins {
            for dependency in plugin.dependencies ?? [] {
                guard let resolved = resolve(dependency) else {
                    results.append(LintResult(
                        severity: .warning,
                        checkId: .PLG001,
                        filePath: pluginsFilePath,
                        message: "Plugin \"\(plugin.fullName)\" depends on \"\(dependency)\", which is not installed.",
                        fix: "Install the \"\(dependency)\" plugin, or remove the dependency from \"\(plugin.name)\".",
                        displayPath: "Plugins"
                    ))
                    continue
                }
                if !resolved.enabled {
                    results.append(LintResult(
                        severity: .warning,
                        checkId: .PLG001,
                        filePath: pluginsFilePath,
                        message: "Plugin \"\(plugin.fullName)\" depends on \"\(dependency)\", which is installed but disabled.",
                        fix: "Enable the \"\(resolved.fullName)\" plugin, or remove the dependency from \"\(plugin.name)\".",
                        displayPath: "Plugins"
                    ))
                }
            }
        }

        // PLG002: dependency cycles
        for fullName in cyclicPluginFullNames(plugins: plugins, resolve: resolve).sorted() {
            results.append(LintResult(
                severity: .error,
                checkId: .PLG002,
                filePath: pluginsFilePath,
                message: "Plugin \"\(fullName)\" is part of a dependency cycle.",
                fix: "Break the cycle so plugin load order is well-defined.",
                displayPath: "Plugins"
            ))
        }

        // PLG003: no components contributed
        for plugin in plugins where (plugin.components ?? []).isEmpty {
            results.append(LintResult(
                severity: .info,
                checkId: .PLG003,
                filePath: pluginsFilePath,
                message: "Plugin \"\(plugin.fullName)\" contributes no commands, skills, or hooks.",
                fix: "Verify the plugin is configured correctly, or remove it if unused.",
                displayPath: "Plugins"
            ))
        }

        return results
    }

    /// Anchor path for plugin lint results. Plugin enablement lives in
    /// settings.json, so results point there for "reveal in Finder" parity with
    /// the CFG family.
    private var pluginsFilePath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("settings.json")
            .path
    }

    /// Returns the set of plugin fullNames that participate in at least one
    /// dependency cycle. Uses iterative DFS with a recursion stack; only edges
    /// that resolve to a known plugin are followed (unresolved deps are PLG001's
    /// concern, not PLG002's).
    private func cyclicPluginFullNames(
        plugins: [PluginInfo],
        resolve: (String) -> PluginInfo?
    ) -> Set<String> {
        // Adjacency by fullName -> resolved dependency fullNames.
        var adjacency: [String: [String]] = [:]
        for plugin in plugins {
            let edges = (plugin.dependencies ?? []).compactMap { resolve($0)?.fullName }
            adjacency[plugin.fullName] = edges
        }

        var cyclic: Set<String> = []
        var color: [String: Int] = [:]   // 0 = unvisited, 1 = in-stack, 2 = done

        for start in adjacency.keys where color[start] == nil {
            // Iterative DFS. Each stack frame tracks the node and its next edge.
            var stack: [(node: String, index: Int)] = [(start, 0)]
            color[start] = 1

            while let frame = stack.last {
                let edges = adjacency[frame.node] ?? []
                if frame.index < edges.count {
                    stack[stack.count - 1].index += 1
                    let next = edges[frame.index]
                    switch color[next] {
                    case 1:
                        // Back-edge: every node currently on the stack from `next`
                        // onward is in the cycle.
                        if let cycleStart = stack.firstIndex(where: { $0.node == next }) {
                            for frame in stack[cycleStart...] {
                                cyclic.insert(frame.node)
                            }
                        }
                    case 2:
                        break
                    default:
                        color[next] = 1
                        stack.append((next, 0))
                    }
                } else {
                    color[frame.node] = 2
                    stack.removeLast()
                }
            }
        }

        return cyclic
    }
}
