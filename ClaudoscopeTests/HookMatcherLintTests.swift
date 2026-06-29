import XCTest
@testable import Claudoscope

/// Tests for the HOOK lint family (matcher validation) and its matcher
/// classifier. Each lint test feeds synthetic HookEventGroups directly to
/// `lintHooks`, mirroring how the orchestrator calls it.
final class HookMatcherLintTests: XCTestCase {

    private func group(_ event: String, _ matchers: [String]) -> HookEventGroup {
        let rules = matchers.map { matcher in
            HookRule(
                id: UUID().uuidString,
                matcher: matcher,
                hooks: [HookCommand(type: "command", command: "true", timeout: nil)],
                source: .user
            )
        }
        return HookEventGroup(event: event, rules: rules)
    }

    private func lint(_ groups: [HookEventGroup], mcp: Set<String> = []) async -> [LintResult] {
        await ConfigLinterService().lintHooks(hookGroups: groups, mcpServerNames: mcp)
    }

    private func ids(_ results: [LintResult]) -> [LintCheckId] { results.map(\.checkId) }

    // MARK: - classifyMatcher

    func testClassifyMatchAll() {
        XCTAssertEqual(ConfigLinterService.classifyMatcher("*"), .matchAll)
        XCTAssertEqual(ConfigLinterService.classifyMatcher(""), .matchAll)
    }

    func testClassifyExactList() {
        XCTAssertEqual(ConfigLinterService.classifyMatcher("Bash"), .exactList(["Bash"]))
        XCTAssertEqual(ConfigLinterService.classifyMatcher("Bash|PowerShell"), .exactList(["Bash", "PowerShell"]))
        XCTAssertEqual(ConfigLinterService.classifyMatcher("Bash, PowerShell"), .exactList(["Bash", "PowerShell"]))
        XCTAssertEqual(ConfigLinterService.classifyMatcher("mcp__memory"), .exactList(["mcp__memory"]))
    }

    func testClassifyRegex() {
        XCTAssertEqual(ConfigLinterService.classifyMatcher("mcp__brave-search"), .regex) // hyphen
        XCTAssertEqual(ConfigLinterService.classifyMatcher("mcp__memory__.*"), .regex)   // dot-star
        XCTAssertEqual(ConfigLinterService.classifyMatcher("^Notebook"), .regex)
    }

    // MARK: - HOOK001 (mcp__ matcher with no tool segment)

    func testHOOK001FiresForBareMcpServerExact() async {
        let r = await lint([group("PreToolUse", ["mcp__memory"])])
        XCTAssertTrue(ids(r).contains(.HOOK001))
        XCTAssertEqual(
            r.first { $0.checkId == .HOOK001 }?.fix,
            "Replace \"mcp__memory\" with \"mcp__memory__.*\" to match all tools from that server."
        )
    }

    func testHOOK001FiresForHyphenatedMcpServer() async {
        let r = await lint([group("PreToolUse", ["mcp__brave-search"])])
        XCTAssertTrue(ids(r).contains(.HOOK001))
    }

    func testHOOK001DoesNotFireForWildcardToolMatcher() async {
        let r = await lint([group("PreToolUse", ["mcp__memory__.*"])])
        XCTAssertFalse(ids(r).contains(.HOOK001))
    }

    func testHOOK001DoesNotFireForSpecificTool() async {
        let r = await lint([group("PreToolUse", ["mcp__memory__store"])])
        XCTAssertFalse(ids(r).contains(.HOOK001))
    }

    // MARK: - HOOK002 (comma-separated matcher)

    func testHOOK002FiresForCommaSeparated() async {
        let r = await lint([group("PreToolUse", ["Bash,PowerShell"])])
        XCTAssertTrue(ids(r).contains(.HOOK002))
    }

    func testHOOK002DoesNotFireForPipeSeparated() async {
        let r = await lint([group("PreToolUse", ["Bash|PowerShell"])])
        XCTAssertFalse(ids(r).contains(.HOOK002))
    }

    // MARK: - HOOK003 (unknown MCP server)

    func testHOOK003FiresForUnknownServer() async {
        let r = await lint([group("PreToolUse", ["mcp__ghost__.*"])], mcp: ["context7", "memory"])
        XCTAssertTrue(ids(r).contains(.HOOK003))
    }

    func testHOOK003DoesNotFireForKnownServer() async {
        let r = await lint([group("PreToolUse", ["mcp__memory__.*"])], mcp: ["memory"])
        XCTAssertFalse(ids(r).contains(.HOOK003))
    }

    func testHOOK003DoesNotFireWhenNoServersLoaded() async {
        let r = await lint([group("PreToolUse", ["mcp__ghost__.*"])], mcp: [])
        XCTAssertFalse(ids(r).contains(.HOOK003))
    }

    // MARK: - HOOK004 (matcher on an event that ignores it)

    func testHOOK004FiresForMatcherOnStop() async {
        let r = await lint([group("Stop", ["Bash"])])
        XCTAssertTrue(ids(r).contains(.HOOK004))
    }

    func testHOOK004DoesNotFireForEmptyMatcherOnStop() async {
        let r = await lint([group("Stop", [""])])
        XCTAssertFalse(ids(r).contains(.HOOK004))
    }

    func testHOOK004DoesNotFireForToolEvent() async {
        let r = await lint([group("PreToolUse", ["Bash"])])
        XCTAssertFalse(ids(r).contains(.HOOK004))
    }

    // MARK: - Clean config

    func testCleanMatchersProduceNoFindings() async {
        let r = await lint([
            group("PreToolUse", ["Bash|PowerShell", "mcp__memory__.*", "*"]),
            group("Stop", [""])
        ], mcp: ["memory"])
        XCTAssertTrue(r.isEmpty, "Expected no hook findings, got \(ids(r))")
    }
}
