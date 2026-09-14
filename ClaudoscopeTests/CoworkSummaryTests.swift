import XCTest
@testable import Claudoscope

final class CoworkSummaryTests: XCTestCase {
    private var tempDir: URL!
    private var service: CoworkService!
    private let table = PricingTables.table(provider: .anthropic, region: .global)

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudoscope-cowork-summary-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        service = CoworkService(supportDir: tempDir)
    }

    override func tearDown() async throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    // MARK: - Fixtures

    /// Two billable assistant records on two LOCAL days (48h apart), no
    /// stop_reason anywhere (the orphan-stream path, Cowork's normal shape).
    private var twoDayLines: [String] {
        [
            #"{"type":"user","uuid":"u0","session_id":"inner-cli","_audit_timestamp":"2026-06-09T12:00:00.000Z","message":{"role":"user","content":"make a deck"}}"#,
            #"{"type":"assistant","uuid":"u1","session_id":"inner-cli","_audit_timestamp":"2026-06-09T12:00:05.000Z","message":{"id":"msg_day1","type":"message","role":"assistant","model":"claude-sonnet-4-6","content":[{"type":"text","text":"working"}],"usage":{"input_tokens":1000,"output_tokens":2000}}}"#,
            #"{"type":"assistant","uuid":"u2","session_id":"inner-cli","_audit_timestamp":"2026-06-11T12:00:00.000Z","message":{"id":"msg_day2","type":"message","role":"assistant","model":"claude-sonnet-4-6","content":[{"type":"text","text":"done"}],"usage":{"input_tokens":500,"output_tokens":1000}}}"#,
        ]
    }

    private func standardLine(msgId: String) -> String {
        #"{"type":"assistant","uuid":"u-std","session_id":"inner-cli","_audit_timestamp":"2026-06-10T10:00:00.000Z","message":{"id":"\#(msgId)","type":"message","role":"assistant","model":"claude-sonnet-4-6","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":1000,"output_tokens":2000,"speed":"standard"}}}"#
    }

    private func fastLine(msgId: String) -> String {
        #"{"type":"assistant","uuid":"u-fast","session_id":"inner-cli","_audit_timestamp":"2026-06-10T10:00:00.000Z","message":{"id":"\#(msgId)","type":"message","role":"assistant","model":"claude-sonnet-4-6","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":1000,"output_tokens":2000,"speed":"fast"}}}"#
    }

    /// A Sonnet 5 record on a caller-chosen day. Sonnet 5's rate depends on the
    /// message date, so these exercise the dated-rate lookup through the Cowork
    /// path (which derives its day from `_audit_timestamp` via CoworkRecordAdapter).
    private func sonnet5Line(msgId: String, uuid: String, utcTimestamp: String) -> String {
        #"{"type":"assistant","uuid":"\#(uuid)","session_id":"inner-cli","_audit_timestamp":"\#(utcTimestamp)","message":{"id":"\#(msgId)","type":"message","role":"assistant","model":"claude-sonnet-5","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":1000,"output_tokens":2000}}}"#
    }

    /// Two Sonnet 5 records straddling the introductory-pricing cutoff. Midday UTC
    /// so each lands on the intended LOCAL day in any timezone the suite runs in.
    private var sonnet5StraddleLines: [String] {
        [
            sonnet5Line(msgId: "msg_intro", uuid: "u-intro", utcTimestamp: "2026-08-31T12:00:00.000Z"),
            sonnet5Line(msgId: "msg_standard", uuid: "u-standard", utcTimestamp: "2026-09-01T12:00:00.000Z"),
        ]
    }

    private func makeSession(id: String, title: String?, transcriptLines: [String]?) throws -> CoworkSession {
        var transcriptURL: URL?
        if let transcriptLines {
            let url = tempDir.appendingPathComponent("\(id)-audit.jsonl")
            try (transcriptLines.joined(separator: "\n") + "\n")
                .write(to: url, atomically: true, encoding: .utf8)
            transcriptURL = url
        }
        return CoworkSession(
            sessionId: id,
            projectId: "workspace-uuid-1",
            cliSessionId: "inner-cli",
            processName: "proc-name",
            title: title,
            initialMessage: nil,
            model: "claude-sonnet-4-6",
            cwd: nil,
            createdAt: nil,
            lastActivityAt: nil,
            effectiveLastActivity: Date(),
            isArchived: false,
            detectedFiles: [],
            slashCommandNames: [],
            metadataURL: tempDir.appendingPathComponent("\(id).json"),
            transcriptURL: transcriptURL
        )
    }

    // MARK: - Summary synthesis

    func testSummaryCostMatchesCoworkStatsTotals() async throws {
        // Mix of standard, fast, and dated-rate records: the two billing paths must
        // agree (guards both the speedMultiplier parity and the per-message date
        // parity between CoworkStats.totals and SessionParser.parseMetadata).
        let session = try makeSession(
            id: "local_s1",
            title: "My Deck",
            transcriptLines: twoDayLines
                + [standardLine(msgId: "msg_std"), fastLine(msgId: "msg_fast")]
                + sonnet5StraddleLines
        )
        let dataOpt = await service.loadSessionData(for: session, pricingTable: table)
        let data = try XCTUnwrap(dataOpt)
        let totals = CoworkStats.totals(records: data.parsed.records, pricingTable: table)

        XCTAssertGreaterThan(data.summary.estimatedCost, 0)
        XCTAssertEqual(data.summary.estimatedCost, totals.cost, accuracy: 0.000001)
    }

    func testFastModeBilledAtMultiplier() async throws {
        let standard = try makeSession(id: "local_std", title: nil, transcriptLines: [standardLine(msgId: "msg_a")])
        let fast = try makeSession(id: "local_fast", title: nil, transcriptLines: [fastLine(msgId: "msg_b")])

        let stdData = await service.loadSessionData(for: standard, pricingTable: table)
        let fastData = await service.loadSessionData(for: fast, pricingTable: table)
        let stdCost = try XCTUnwrap(stdData).summary.estimatedCost
        let fastCost = try XCTUnwrap(fastData).summary.estimatedCost

        XCTAssertGreaterThan(stdCost, 0)
        XCTAssertEqual(fastCost, stdCost * fastModeRateMultiplier, accuracy: 0.000001)
    }

    func testDailyContributionsSumToEstimatedCost() async throws {
        let session = try makeSession(id: "local_s2", title: nil, transcriptLines: twoDayLines)
        let dataOpt = await service.loadSessionData(for: session, pricingTable: table)
        let summary = try XCTUnwrap(dataOpt).summary

        XCTAssertEqual(summary.dailyContributions.count, 2, "48h-apart records must land on two local days")
        let daySum = summary.dailyContributions.reduce(0.0) { $0 + $1.estimatedCost }
        XCTAssertEqual(daySum, summary.estimatedCost, accuracy: 0.000001)
    }

    func testCoworkIdentityOverridesApplied() async throws {
        let session = try makeSession(id: "local_s3", title: "Quarterly Report", transcriptLines: twoDayLines)
        let dataOpt = await service.loadSessionData(for: session, pricingTable: table)
        let summary = try XCTUnwrap(dataOpt).summary

        XCTAssertEqual(summary.id, "local_s3")
        XCTAssertEqual(summary.projectId, "workspace-uuid-1")
        XCTAssertEqual(summary.title, "Quarterly Report", "title must come from Cowork metadata, not the transcript")
        XCTAssertTrue(summary.isCowork)
        XCTAssertFalse(summary.isSubagent)
    }

    func testNoTranscriptReturnsNil() async throws {
        let session = try makeSession(id: "local_s4", title: nil, transcriptLines: nil)
        let data = await service.loadSessionData(for: session, pricingTable: table)
        XCTAssertNil(data)
    }

    // MARK: - dayTotals helper (popover "Today" fold)

    func testDayTotalsFiltersToRequestedDayOnly() async throws {
        let session = try makeSession(id: "local_s5", title: nil, transcriptLines: twoDayLines)
        let dataOpt = await service.loadSessionData(for: session, pricingTable: table)
        let summary = try XCTUnwrap(dataOpt).summary
        let days = summary.dailyContributions.sorted { $0.date < $1.date }
        XCTAssertEqual(days.count, 2)

        // Asking for day 2 must return only day 2's tokens/cost: a session
        // resumed across midnight must not pull day 1 spend into "today".
        let day2 = days[1]
        let result = SessionStore.dayTotals(sessions: [summary], dayKey: day2.date)
        XCTAssertEqual(result.tokens, day2.inputTokens + day2.outputTokens)
        XCTAssertEqual(result.cost, day2.estimatedCost, accuracy: 0.000001)

        // A day with no contributions returns zero.
        let empty = SessionStore.dayTotals(sessions: [summary], dayKey: "1999-01-01")
        XCTAssertEqual(empty.tokens, 0)
        XCTAssertEqual(empty.cost, 0, accuracy: 0.000001)
    }

    // MARK: - Field forwarding

    /// The Cowork path rebuilds a SessionSummary by hand from the parser's
    /// output, so any field it forgets to copy is silently lost for every
    /// Cowork session. That is how hookRunStats went missing for a whole
    /// release.
    ///
    /// A value comparison against a direct parseMetadata is not possible here:
    /// the Cowork path adapts `_audit_timestamp` into `timestamp` first, so the
    /// two parses legitimately differ on dates. Instead this pins the property
    /// count. Adding a field to SessionSummary fails this test, which is the
    /// prompt to go forward it in CoworkService.loadSessionData.
    func testSessionSummaryPropertyCountIsPinnedForCoworkForwarding() {
        let probe = SessionSummary(
            id: "x", projectId: "p", slug: nil, title: "t",
            firstTimestamp: "", lastTimestamp: "", messageCount: 0, primaryModel: nil,
            totalInputTokens: 0, totalOutputTokens: 0, totalCacheReadTokens: 0,
            totalCacheCreationTokens: 0, totalCacheCreation5mTokens: 0,
            totalCacheCreation1hTokens: 0, compactionCount: 0, estimatedCost: 0,
            hasError: false, modelBreakdown: [], toolCallCount: 0,
            observability: .empty, isSubagent: false, dailyContributions: []
        )
        XCTAssertEqual(
            Mirror(reflecting: probe).children.count, 34,
            """
            SessionSummary gained or lost a stored property. Forward it in \
            CoworkService.loadSessionData (everything except id, projectId, \
            title, isSubagent and isCowork is pass-through), then update this \
            count. Skipping the forward silently drops the field for every \
            Cowork session.
            """
        )
    }

    /// The pass-through actually happens end to end, for the fields most
    /// recently added and therefore most likely to have been missed.
    func testRebuiltSummaryForwardsAttributionFields() async throws {
        let lines = twoDayLines + [
            #"{"type":"assistant","uuid":"u-attr","session_id":"inner-cli","_audit_timestamp":"2026-06-10T09:00:00.000Z","attributionSkill":"hairline-deck","attributionMcpServer":"srv","attributionMcpTool":"fetch","sessionKind":"bg","message":{"id":"msg_attr","type":"message","role":"assistant","model":"claude-sonnet-4-6","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":1000,"output_tokens":2000}}}"#
        ]
        let session = try makeSession(id: "local_fwd", title: "Fwd", transcriptLines: lines)
        let dataOpt = await service.loadSessionData(for: session, pricingTable: table)
        let rebuilt = try XCTUnwrap(dataOpt).summary

        XCTAssertEqual(rebuilt.sessionKind, "bg")
        XCTAssertEqual(rebuilt.skillBreakdown?.first?.skill, "hairline-deck")
        XCTAssertEqual(rebuilt.mcpBreakdown?.first?.server, "srv")
        XCTAssertEqual(rebuilt.mcpBreakdown?.first?.tool, "fetch")
        // The per-day arrays survive the rebuild too, which is what
        // date-windowed analytics reads.
        XCTAssertEqual(
            rebuilt.dailyContributions.flatMap { $0.skillBreakdown ?? [] }.count, 1
        )
        // Intentional overrides still applied.
        XCTAssertTrue(rebuilt.isCowork)
        XCTAssertFalse(rebuilt.isSubagent)
        XCTAssertEqual(rebuilt.title, session.displayTitle)
    }
}
