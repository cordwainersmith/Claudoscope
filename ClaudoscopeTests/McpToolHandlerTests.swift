import XCTest
import MCP
@testable import Claudoscope

final class McpToolHandlerTests: XCTestCase {
    private var claudeDir: URL!

    override func setUp() {
        super.setUp()
        claudeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-handler-test-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: claudeDir)
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeSession(
        id: String,
        projectId: String = "-Users-test-projects-alpha",
        title: String = "untitled",
        lastTimestamp: String = "2026-07-15T10:00:00Z",
        cost: Double = 1.0,
        isSubagent: Bool = false,
        dailyContributions: [DailyContribution] = []
    ) -> SessionSummary {
        SessionSummary(
            id: id,
            projectId: projectId,
            slug: nil,
            title: title,
            firstTimestamp: lastTimestamp,
            lastTimestamp: lastTimestamp,
            messageCount: 3,
            primaryModel: "claude-fable-5",
            totalInputTokens: 100,
            totalOutputTokens: 200,
            totalCacheReadTokens: 50,
            totalCacheCreationTokens: 25,
            totalCacheCreation5mTokens: 25,
            totalCacheCreation1hTokens: 0,
            compactionCount: 0,
            estimatedCost: cost,
            hasError: false,
            modelBreakdown: [],
            toolCallCount: 2,
            observability: .empty,
            isSubagent: isSubagent,
            dailyContributions: dailyContributions
        )
    }

    private func makeContribution(date: String, cost: Double) -> DailyContribution {
        DailyContribution(
            date: date,
            inputTokens: 100,
            outputTokens: 200,
            cacheReadTokens: 50,
            cacheCreationTokens: 25,
            cacheCreation5mTokens: 25,
            cacheCreation1hTokens: 0,
            estimatedCost: cost,
            modelBreakdown: [ModelDayCost(
                model: "fable",
                inputTokens: 100,
                outputTokens: 200,
                cacheReadTokens: 50,
                estimatedCost: cost,
                turnCount: 1
            )]
        )
    }

    private func makeContext(
        projects: [Project],
        sessionsByProject: [String: [SessionSummary]],
        canonOptedIn: Set<String> = []
    ) -> McpToolContext {
        let snapshot = McpStoreSnapshot(
            projects: projects,
            sessionsByProject: sessionsByProject,
            pricingTable: PricingTables.table(provider: .anthropic, region: .global),
            canonOptedInProjectIds: canonOptedIn,
            bundledCanonProtocolVersion: 1
        )
        return McpToolContext(
            snapshot: { snapshot },
            configService: ConfigService(claudeDir: claudeDir),
            linterService: ConfigLinterService(),
            plansService: PlansService(claudeDir: claudeDir),
            claudeDir: claudeDir
        )
    }

    private func resultJSON(_ result: CallTool.Result) throws -> [String: Any] {
        XCTAssertNotEqual(result.isError, true, "tool returned error: \(resultText(result))")
        let data = try XCTUnwrap(resultText(result).data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func resultText(_ result: CallTool.Result) -> String {
        if case .text(let text, _, _) = result.content.first {
            return text
        }
        return ""
    }

    // MARK: - get_usage

    func testGetUsageMatchesAnalyticsEngine() async throws {
        let project = Project(id: "-Users-test-projects-alpha", name: "alpha", path: "/tmp/alpha", sessionCount: 2)
        let sessions = [
            makeSession(id: "s1", cost: 2.5, dailyContributions: [makeContribution(date: "2026-07-14", cost: 2.5)]),
            makeSession(id: "s2", cost: 1.5, dailyContributions: [makeContribution(date: "2026-07-15", cost: 1.5)]),
        ]
        let context = makeContext(projects: [project], sessionsByProject: [project.id: sessions])

        let result = await McpToolHandlers.dispatch(name: "get_usage", arguments: ["period": "all"], context: context)
        let json = try resultJSON(result)
        let totals = try XCTUnwrap(json["totals"] as? [String: Any])

        let expected = AnalyticsEngine.compute(
            sessions: sessions.map { ($0, project) },
            pricingTable: PricingTables.table(provider: .anthropic, region: .global)
        )
        XCTAssertEqual(totals["cost"] as? Double, McpToolHandlers.round4(expected.totalCost))
        XCTAssertEqual(totals["sessions"] as? Int, expected.totalSessions)
        XCTAssertEqual(totals["tokens"] as? Int, expected.totalTokens)
        XCTAssertEqual((json["per_day"] as? [[String: Any]])?.count, expected.dailyUsage.count)
    }

    func testCustomPeriodDayWindowing() async throws {
        let project = Project(id: "-Users-test-projects-alpha", name: "alpha", path: "/tmp/alpha", sessionCount: 1)
        let session = makeSession(id: "s1", cost: 4.0, dailyContributions: [
            makeContribution(date: "2026-07-10", cost: 1.0),
            makeContribution(date: "2026-07-11", cost: 3.0),
        ])
        let context = makeContext(projects: [project], sessionsByProject: [project.id: [session]])

        // Half-open [from, to]: to=2026-07-10 must include only the 07-10 day.
        let result = await McpToolHandlers.dispatch(
            name: "get_usage",
            arguments: ["period": "custom", "from": "2026-07-10", "to": "2026-07-10"],
            context: context
        )
        let json = try resultJSON(result)
        let perDay = try XCTUnwrap(json["per_day"] as? [[String: Any]])
        XCTAssertEqual(perDay.map { $0["date"] as? String }, ["2026-07-10"])
        let totals = try XCTUnwrap(json["totals"] as? [String: Any])
        XCTAssertEqual(totals["cost"] as? Double, 1.0)
    }

    func testGetUsageRejectsBadPeriod() async {
        let context = makeContext(projects: [], sessionsByProject: [:])
        let result = await McpToolHandlers.dispatch(name: "get_usage", arguments: ["period": "yesterday"], context: context)
        XCTAssertEqual(result.isError, true)
    }

    // MARK: - project resolution

    func testProjectResolutionByIdAndName() async throws {
        let projectA = Project(id: "-Users-test-projects-alpha", name: "alpha", path: "/tmp/a", sessionCount: 1)
        let projectB = Project(id: "-Users-test-projects-beta", name: "beta", path: "/tmp/b", sessionCount: 1)
        let context = makeContext(
            projects: [projectA, projectB],
            sessionsByProject: [
                projectA.id: [makeSession(id: "sa")],
                projectB.id: [makeSession(id: "sb", projectId: projectB.id)],
            ]
        )
        let snapshot = await context.snapshot()

        let byId = try await McpToolHandlers.resolveProject(projectB.id, snapshot: snapshot, configService: context.configService)
        XCTAssertEqual(byId.name, "beta")
        let byName = try await McpToolHandlers.resolveProject("ALPHA", snapshot: snapshot, configService: context.configService)
        XCTAssertEqual(byName.id, projectA.id)

        do {
            _ = try await McpToolHandlers.resolveProject("nope", snapshot: snapshot, configService: context.configService)
            XCTFail("expected unknown-project error")
        } catch let error as McpToolHandlers.McpToolError {
            XCTAssertTrue(error.message.contains("Unknown project"))
        }
    }

    // MARK: - list/search sessions

    func testListSessionsExcludesSubagentsByDefault() async throws {
        let project = Project(id: "-Users-test-projects-alpha", name: "alpha", path: "/tmp/a", sessionCount: 2)
        let context = makeContext(projects: [project], sessionsByProject: [project.id: [
            makeSession(id: "main-1"),
            makeSession(id: "agent-1", isSubagent: true),
        ]])

        let defaultResult = await McpToolHandlers.dispatch(name: "list_sessions", arguments: nil, context: context)
        let defaultSessions = try XCTUnwrap(try resultJSON(defaultResult)["sessions"] as? [[String: Any]])
        XCTAssertEqual(defaultSessions.map { $0["id"] as? String }, ["main-1"])

        let withSubagents = await McpToolHandlers.dispatch(
            name: "list_sessions",
            arguments: ["include_subagents": true],
            context: context
        )
        let allSessions = try XCTUnwrap(try resultJSON(withSubagents)["sessions"] as? [[String: Any]])
        XCTAssertEqual(allSessions.count, 2)
    }

    func testSearchSessionsMatchesAllTermsAcrossTitleAndProject() async throws {
        let project = Project(id: "-Users-test-projects-alpha", name: "alpha", path: "/tmp/a", sessionCount: 2)
        let context = makeContext(projects: [project], sessionsByProject: [project.id: [
            makeSession(id: "s1", title: "Fix orphan billing bug"),
            makeSession(id: "s2", title: "Add settings toggle"),
        ]])

        let result = await McpToolHandlers.dispatch(
            name: "search_sessions",
            arguments: ["query": "orphan alpha"],
            context: context
        )
        let sessions = try XCTUnwrap(try resultJSON(result)["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.map { $0["id"] as? String }, ["s1"])
    }

    func testGetSessionReturnsFullSummaryAndTranscriptPath() async throws {
        let project = Project(id: "-Users-test-projects-alpha", name: "alpha", path: "/tmp/a", sessionCount: 1)
        let session = makeSession(id: "abc-123", dailyContributions: [makeContribution(date: "2026-07-15", cost: 1.0)])
        let transcriptDir = claudeDir
            .appendingPathComponent("projects")
            .appendingPathComponent(project.id)
        try FileManager.default.createDirectory(at: transcriptDir, withIntermediateDirectories: true)
        let transcript = transcriptDir.appendingPathComponent("abc-123.jsonl")
        try Data("{}".utf8).write(to: transcript)

        let context = makeContext(projects: [project], sessionsByProject: [project.id: [session]])
        let result = await McpToolHandlers.dispatch(name: "get_session", arguments: ["id": "abc-123"], context: context)
        let json = try resultJSON(result)
        XCTAssertEqual(json["transcript_file"] as? String, transcript.path)
        let sessionJSON = try XCTUnwrap(json["session"] as? [String: Any])
        XCTAssertEqual(sessionJSON["id"] as? String, "abc-123")
        XCTAssertEqual((sessionJSON["daily_contributions"] as? [[String: Any]])?.count, 1)
    }

    // MARK: - lint masking

    func testLintFindingNeverSerializesSecretMaterial() throws {
        let planted = "sk-ant-SECRET-VALUE-12345"
        let result = LintResult(
            severity: .error,
            checkId: .SEC001,
            filePath: "/tmp/session.jsonl",
            line: 7,
            message: "Anthropic API key detected (masked): sk-ant-***45",
            fix: "Rotate the key",
            contextLines: ["export KEY=\(planted)"],
            unmaskedSecret: planted
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(McpToolHandlers.lintFinding(result))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains(planted))
        XCTAssertFalse(json.contains("context_lines"))
        XCTAssertFalse(json.contains("unmasked"))
        XCTAssertTrue(json.contains("SEC001"))
    }

    func testLintConfigRunsAgainstEmptyDirWithoutError() async throws {
        let context = makeContext(projects: [], sessionsByProject: [:])
        let result = await McpToolHandlers.dispatch(name: "lint_config", arguments: nil, context: context)
        let json = try resultJSON(result)
        XCTAssertNotNil(json["summary"])
        XCTAssertNotNil(json["findings"])
    }

    // MARK: - get_config masking

    func testGetConfigMasksMcpEnvValues() async throws {
        let settings = claudeDir.appendingPathComponent("settings.json")
        let payload: [String: Any] = [
            "mcpServers": [
                "leaky": [
                    "command": "npx",
                    "args": ["-y", "leaky-server"],
                    "env": ["API_TOKEN": "super-secret-token-999"],
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: settings)

        let context = makeContext(projects: [], sessionsByProject: [:])
        let result = await McpToolHandlers.dispatch(
            name: "get_config",
            arguments: ["kind": "mcp_servers"],
            context: context
        )
        let text = resultText(result)
        XCTAssertFalse(text.contains("super-secret-token-999"))
        let json = try resultJSON(result)
        let servers = try XCTUnwrap(json["mcp_servers"] as? [[String: Any]])
        let leaky = try XCTUnwrap(servers.first { ($0["name"] as? String) == "leaky" })
        XCTAssertEqual((leaky["env_keys"] as? [String: String])?["API_TOKEN"], "***")
    }

    // MARK: - list_plans

    func testListPlansReturnsPointerWithFilePath() async throws {
        let plansDir = claudeDir.appendingPathComponent("plans")
        try FileManager.default.createDirectory(at: plansDir, withIntermediateDirectories: true)
        try Data("# alpha: Add MCP server\n\nbody".utf8).write(to: plansDir.appendingPathComponent("test-plan.md"))

        let context = makeContext(projects: [], sessionsByProject: [:])
        let result = await McpToolHandlers.dispatch(name: "list_plans", arguments: nil, context: context)
        let json = try resultJSON(result)
        let plans = try XCTUnwrap(json["plans"] as? [[String: Any]])
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0]["file"] as? String, plansDir.appendingPathComponent("test-plan.md").path)
    }

    // MARK: - limit clamping

    func testLimitClampsToBounds() {
        XCTAssertEqual(McpToolHandlers.limit(["limit": 5000]), 200)
        XCTAssertEqual(McpToolHandlers.limit(["limit": 0]), 1)
        XCTAssertEqual(McpToolHandlers.limit(nil), 25)
    }

    func testUnknownToolReturnsError() async {
        let context = makeContext(projects: [], sessionsByProject: [:])
        let result = await McpToolHandlers.dispatch(name: "drop_tables", arguments: nil, context: context)
        XCTAssertEqual(result.isError, true)
    }
}
