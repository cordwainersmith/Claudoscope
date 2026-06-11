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
        // Mix of standard and fast records: the two billing paths must agree
        // (guards the speedMultiplier parity between CoworkStats.totals and
        // SessionParser.parseMetadata).
        let session = try makeSession(
            id: "local_s1",
            title: "My Deck",
            transcriptLines: twoDayLines + [standardLine(msgId: "msg_std"), fastLine(msgId: "msg_fast")]
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
}
