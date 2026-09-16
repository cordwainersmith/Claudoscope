import XCTest
@testable import Claudoscope

/// Per-rule tests for the PLG lint family. `lintPlugins(plugins:)` takes the
/// inventory directly, so each test builds a synthetic `[PluginInfo]` and
/// asserts which PLG checks fire — no temp filesystem required.
///
/// - PLG001: a declared dependency is not installed or not enabled.
/// - PLG002: the dependency graph contains a cycle.
/// - PLG003: a plugin contributes no components.
final class PluginLintTests: XCTestCase {
    private let linter = ConfigLinterService()

    // MARK: - Helpers

    private func plugin(
        _ name: String,
        marketplace: String = "mkt",
        enabled: Bool = true,
        components: [String]? = ["skills (1)"],
        dependencies: [String]? = nil,
        installations: [PluginInstallation]? = nil
    ) -> PluginInfo {
        PluginInfo(
            fullName: "\(name)@\(marketplace)",
            name: name,
            marketplace: marketplace,
            enabled: enabled,
            components: components,
            dependencies: dependencies,
            installations: installations
        )
    }

    private func install(
        _ scope: String,
        version: String,
        sha: String? = nil,
        projectPath: String? = nil
    ) -> PluginInstallation {
        PluginInstallation(
            scope: scope, projectPath: projectPath, version: version,
            gitCommitSha: sha, installedAt: nil, lastUpdated: nil
        )
    }

    private func lint(_ plugins: [PluginInfo]) async -> [LintResult] {
        await linter.lintPlugins(plugins: plugins)
    }

    private func contains(_ results: [LintResult], _ id: LintCheckId) -> Bool {
        results.contains { $0.checkId == id }
    }

    private func count(_ results: [LintResult], _ id: LintCheckId) -> Int {
        results.filter { $0.checkId == id }.count
    }

    private func messages(_ results: [LintResult], _ id: LintCheckId) -> [String] {
        results.filter { $0.checkId == id }.map(\.message)
    }

    // MARK: - Empty inventory

    func testEmptyInventoryProducesNoResults() async {
        let results = await lint([])
        XCTAssertTrue(results.isEmpty, "An empty plugin inventory should produce no PLG results")
    }

    // MARK: - PLG001: unsatisfied dependency

    func testPLG001FiresWhenDependencyNotInstalled() async {
        let plugins = [
            plugin("alpha", dependencies: ["ghost"])
        ]
        let results = await lint(plugins)
        XCTAssertTrue(contains(results, .PLG001),
                      "PLG001 should fire when a declared dependency is absent")
        XCTAssertTrue(messages(results, .PLG001).first?.contains("\"ghost\"") ?? false,
                      "PLG001 message should quote the missing dependency name")
    }

    func testPLG001FiresWhenDependencyInstalledButDisabled() async {
        let plugins = [
            plugin("alpha", dependencies: ["beta"]),
            plugin("beta", enabled: false)
        ]
        let results = await lint(plugins)
        XCTAssertEqual(count(results, .PLG001), 1,
                       "PLG001 should fire once for a disabled dependency")
        XCTAssertTrue(messages(results, .PLG001).first?.contains("disabled") ?? false,
                      "PLG001 message should note the dependency is installed but disabled")
    }

    func testPLG001DoesNotFireWhenDependencySatisfiedByName() async {
        let plugins = [
            plugin("alpha", dependencies: ["beta"]),
            plugin("beta")
        ]
        let results = await lint(plugins)
        XCTAssertFalse(contains(results, .PLG001),
                       "PLG001 should not fire when the dependency is installed and enabled")
    }

    func testPLG001DoesNotFireWhenDependencySatisfiedByFullName() async {
        let plugins = [
            plugin("alpha", dependencies: ["beta@mkt"]),
            plugin("beta", marketplace: "mkt")
        ]
        let results = await lint(plugins)
        XCTAssertFalse(contains(results, .PLG001),
                       "PLG001 should resolve a name@marketplace dependency reference")
    }

    func testPLG001FiresOncePerMissingDependency() async {
        let plugins = [
            plugin("alpha", dependencies: ["ghost1", "ghost2"])
        ]
        let results = await lint(plugins)
        XCTAssertEqual(count(results, .PLG001), 2,
                       "PLG001 should fire once per missing dependency")
    }

    // MARK: - PLG002: dependency cycle

    func testPLG002FiresOnMutualCycle() async {
        let plugins = [
            plugin("alpha", dependencies: ["beta"]),
            plugin("beta", dependencies: ["alpha"])
        ]
        let results = await lint(plugins)
        XCTAssertTrue(contains(results, .PLG002),
                      "PLG002 should fire on a two-node dependency cycle")
        // Both participants should be reported.
        XCTAssertEqual(count(results, .PLG002), 2,
                       "Both plugins in the cycle should each get a PLG002 result")
    }

    func testPLG002FiresOnSelfDependency() async {
        let plugins = [
            plugin("alpha", dependencies: ["alpha"])
        ]
        let results = await lint(plugins)
        XCTAssertTrue(contains(results, .PLG002),
                      "PLG002 should fire when a plugin depends on itself")
    }

    func testPLG002FiresOnThreeNodeCycle() async {
        let plugins = [
            plugin("alpha", dependencies: ["beta"]),
            plugin("beta", dependencies: ["gamma"]),
            plugin("gamma", dependencies: ["alpha"])
        ]
        let results = await lint(plugins)
        XCTAssertEqual(count(results, .PLG002), 3,
                       "All three plugins in the cycle should be reported")
    }

    func testPLG002DoesNotFireOnAcyclicChain() async {
        let plugins = [
            plugin("alpha", dependencies: ["beta"]),
            plugin("beta", dependencies: ["gamma"]),
            plugin("gamma")
        ]
        let results = await lint(plugins)
        XCTAssertFalse(contains(results, .PLG002),
                       "PLG002 should not fire on a linear (acyclic) dependency chain")
    }

    func testPLG002DoesNotFireWhenCycleEdgeIsUnresolved() async {
        // alpha -> ghost (missing). No real cycle exists; only PLG001 applies.
        let plugins = [
            plugin("alpha", dependencies: ["ghost"])
        ]
        let results = await lint(plugins)
        XCTAssertFalse(contains(results, .PLG002),
                       "An unresolved dependency edge must not be counted as a cycle")
    }

    // MARK: - PLG003: no components

    func testPLG003FiresWhenComponentsNil() async {
        let plugins = [
            plugin("alpha", components: nil)
        ]
        let results = await lint(plugins)
        XCTAssertTrue(contains(results, .PLG003),
                      "PLG003 should fire when components is nil")
    }

    func testPLG003FiresWhenComponentsEmpty() async {
        let plugins = [
            plugin("alpha", components: [])
        ]
        let results = await lint(plugins)
        XCTAssertTrue(contains(results, .PLG003),
                      "PLG003 should fire when components is an empty list")
    }

    func testPLG003DoesNotFireWhenComponentsPresent() async {
        let plugins = [
            plugin("alpha", components: ["commands (3)", "skills (1)"])
        ]
        let results = await lint(plugins)
        XCTAssertFalse(contains(results, .PLG003),
                       "PLG003 should not fire when the plugin contributes components")
    }

    // MARK: - Combined / clean inventory

    func testHealthyInventoryProducesNoResults() async {
        let plugins = [
            plugin("alpha", components: ["commands (2)"], dependencies: ["beta"]),
            plugin("beta", components: ["skills (1)"])
        ]
        let results = await lint(plugins)
        XCTAssertTrue(results.isEmpty,
                      "A healthy inventory (deps satisfied, components present, no cycles) should be clean")
    }

    func testSubjectNamesAreQuotedForUISurfacing() async {
        // The Config Health UI extracts the first quoted token as the row label,
        // so every PLG message must quote the offending plugin's fullName.
        let plugins = [
            plugin("alpha", components: nil, dependencies: ["ghost"])
        ]
        let results = await lint(plugins)
        for result in results {
            XCTAssertTrue(result.message.contains("\"alpha@mkt\""),
                          "PLG message should quote the plugin fullName for UI row labels: \(result.message)")
        }
    }


    // MARK: - PLG004: scope drift

    func testPLG004FiresWhenTwoScopesRunDifferentCommits() async {
        let p = plugin("frontend-design", installations: [
            install("user", version: "76c85b73", sha: "76c85b7366c8be78ce3ac67dd21945b3960d1a8c"),
            install("project", version: "unknown", sha: "ff2a7b576c20b2f1a777c497455e5d1e443f23e9",
                    projectPath: "/tmp/agent-hive")
        ])
        let r = await lint([p])
        XCTAssertTrue(r.contains { $0.checkId == .PLG004 })
    }

    func testPLG004DoesNotFireWhenBothScopesMatch() async {
        let p = plugin("frontend-design", installations: [
            install("user", version: "1.0.0", sha: "abc123"),
            install("project", version: "1.0.0", sha: "abc123", projectPath: "/tmp/x")
        ])
        let r = await lint([p])
        XCTAssertFalse(r.contains { $0.checkId == .PLG004 })
    }

    func testPLG004DoesNotFireForASingleInstall() async {
        let p = plugin("swift-lsp", installations: [install("user", version: "1.0.0", sha: "abc123")])
        let r = await lint([p])
        XCTAssertFalse(r.contains { $0.checkId == .PLG004 })
    }

    /// installed_plugins.json missing, or not listing this plugin.
    func testPLG004DoesNotFireWithoutInstallRecords() async {
        let r = await lint([plugin("swift-lsp")])
        XCTAssertFalse(r.contains { $0.checkId == .PLG004 })
    }

    /// Same commit, different version string, is a labelling difference in the
    /// cache path, not two different bodies of code.
    func testScopeDriftComparesVersionAndSha() {
        let sameCode = plugin("p", installations: [
            install("user", version: "1.0.0", sha: "abc"),
            install("project", version: "1.0.0", sha: "abc")
        ])
        XCTAssertFalse(sameCode.hasScopeDrift)

        let differentVersion = plugin("p", installations: [
            install("user", version: "1.0.0", sha: "abc"),
            install("project", version: "1.1.0", sha: "abc")
        ])
        XCTAssertTrue(differentVersion.hasScopeDrift)
    }

    func testShortShaTruncatesToEightCharacters() {
        XCTAssertEqual(install("user", version: "1", sha: "76c85b7366c8be78").shortSha, "76c85b73")
        XCTAssertEqual(install("user", version: "1", sha: "abc").shortSha, "abc")
        XCTAssertNil(install("user", version: "1").shortSha)
    }
}
