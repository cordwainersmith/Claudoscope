import XCTest
import GRDB
@testable import Claudoscope

/// A conversation handed off to a background job (Claude Code 2.1.296): the
/// parent ends with a `continued-in` record, and the job's file carries
/// copies of the parent's records (same uuids, `sessionId` rewritten to the
/// job's). The copies belong to the parent: they show in the job's chat but
/// count in none of its figures.
@MainActor
final class ContinuedSessionBillingTests: XCTestCase {

    // MARK: - Fixtures

    @MainActor
    private final class Upserts {
        var summaries: [SessionSummary] = []
        func job() -> SessionSummary? { summaries.first { $0.id == "child-id" } }
    }

    private let table = PricingTables.anthropic
    private var claudeDir: URL!
    private var projectDir: URL { claudeDir.appendingPathComponent("projects/-Users-x") }

    override func setUpWithError() throws {
        claudeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudoscope-continued-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: claudeDir)
    }

    private func user(_ uuid: String, _ session: String, at ts: String) -> String {
        """
        {"type":"user","uuid":"\(uuid)","sessionId":"\(session)","timestamp":"\(ts)","message":{"role":"user","content":"go"}}
        """
    }

    private func assistant(_ uuid: String, _ session: String, msgId: String, at ts: String, input: Int, output: Int) -> String {
        """
        {"type":"assistant","uuid":"\(uuid)","sessionId":"\(session)","timestamp":"\(ts)","message":{"role":"assistant","id":"\(msgId)","model":"claude-opus-4-5-20250120","stop_reason":"end_turn","usage":{"input_tokens":\(input),"output_tokens":\(output)}}}
        """
    }

    private let t0 = "2026-04-26T10:00:00.000Z"
    private let t1 = "2026-04-26T10:00:05.000Z"
    private let handoff = "2026-04-26T10:01:00.000Z"
    private let t2 = "2026-04-26T10:02:00.000Z"
    private let t3 = "2026-04-26T10:02:05.000Z"

    /// The job's own records: a title, then one new turn after the handoff.
    private var jobOwnLines: [String] {
        [
            "{\"type\":\"custom-title\",\"customTitle\":\"Hello\",\"sessionId\":\"child-id\"}",
            user("u2", "child-id", at: t2),
            assistant("a2", "child-id", msgId: "msg_B", at: t3, input: 50, output: 75),
        ]
    }

    private func write(_ name: String, _ lines: [String]) throws -> URL {
        let url = projectDir.appendingPathComponent("\(name).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A `queue-operation` stamped at the handoff. Some jobs carry one ahead of
    /// the copies, so the copies' timestamps are older than the record before them.
    private var queuedAtHandoff: String {
        "{\"type\":\"queue-operation\",\"operation\":\"enqueue\",\"timestamp\":\"\(handoff)\",\"sessionId\":\"child-id\"}"
    }

    /// The parent transcript, and the job's file with the copies spliced in
    /// after the title and any `lead` records, the way Claude Code writes it.
    private func writePair(lead: [String] = []) throws -> (parent: URL, job: URL) {
        let parent = try write("parent-id", [
            user("u1", "parent-id", at: t0),
            assistant("a1", "parent-id", msgId: "msg_A", at: t1, input: 100, output: 200),
            "{\"type\":\"continued-in\",\"continuedInSessionId\":\"child-id\",\"sessionId\":\"parent-id\",\"timestamp\":\"\(handoff)\"}",
        ])
        let copies = [
            user("u1", "child-id", at: t0),
            assistant("a1", "child-id", msgId: "msg_A", at: t1, input: 100, output: 200),
        ]
        let job = try write("child-id", [jobOwnLines[0]] + lead + copies + jobOwnLines.dropFirst())
        return (parent, job)
    }

    // MARK: - Parser

    func testParentRecordsWhereItContinued() async throws {
        let (parent, _) = try writePair()
        let summary = try await SessionParser().parseMetadata(url: parent, sessionId: "parent-id", pricingTable: table)
        XCTAssertEqual(summary.continuedInSessionId, "child-id")
        XCTAssertNil(summary.continuedFromSessionId)
        XCTAssertEqual(summary.totalInputTokens, 100)
    }

    func testCopiesCountInNoneOfTheJobsFigures() async throws {
        let (parent, job) = try writePair()
        let ownOnly = try write("own-only", jobOwnLines)
        let parser = SessionParser()
        let continued = try await parser.parseMetadata(
            url: job, sessionId: "child-id", pricingTable: table, continuationParent: parent
        )
        let expected = try await parser.parseMetadata(url: ownOnly, sessionId: "child-id", pricingTable: table)

        XCTAssertEqual(continued.continuedFromSessionId, "parent-id")
        XCTAssertEqual(continued.totalInputTokens, 50)
        XCTAssertEqual(continued.estimatedCost, expected.estimatedCost, accuracy: 1e-12)
        XCTAssertEqual(continued.dailyContributions, expected.dailyContributions)
        XCTAssertEqual(continued.messageCount, expected.messageCount)
        XCTAssertEqual(continued.firstTimestamp, t2, "the job starts at the handoff, not with the copied history")
        XCTAssertEqual(continued.title, "Hello")
    }

    func testCopiesAfterAQueueOperationLeaveTheStartAtTheHandoff() async throws {
        let (parent, job) = try writePair(lead: [queuedAtHandoff])
        let ownOnly = try write("own-only", [jobOwnLines[0], queuedAtHandoff] + jobOwnLines.dropFirst())
        let parser = SessionParser()
        let continued = try await parser.parseMetadata(
            url: job, sessionId: "child-id", pricingTable: table, continuationParent: parent
        )
        let expected = try await parser.parseMetadata(url: ownOnly, sessionId: "child-id", pricingTable: table)

        XCTAssertEqual(continued.firstTimestamp, handoff,
                       "copies older than the record before them must not move the start back")
        XCTAssertEqual(continued.lastTimestamp, expected.lastTimestamp)
        XCTAssertEqual(continued.estimatedCost, expected.estimatedCost, accuracy: 1e-12)
        XCTAssertEqual(continued.dailyContributions, expected.dailyContributions)
        XCTAssertEqual(continued.messageCount, expected.messageCount)
    }

    func testMissingParentBillsEverything() async throws {
        let (_, job) = try writePair()
        let gone = projectDir.appendingPathComponent("gone.jsonl")
        let summary = try await SessionParser().parseMetadata(
            url: job, sessionId: "child-id", pricingTable: table, continuationParent: gone
        )
        XCTAssertEqual(summary.totalInputTokens, 150, "with the parent gone, the job is the only record of that spend")
        XCTAssertEqual(summary.firstTimestamp, t0)
        XCTAssertNil(summary.continuedFromSessionId)
    }

    func testChatKeepsCopiesWhileTotalsSkipThem() async throws {
        let (parent, job) = try writePair()
        let session = try await SessionParser().parse(url: job, sessionId: "child-id", continuationParent: parent)

        XCTAssertTrue(session.records.contains { $0.uuid == "u1" }, "the chat still shows the copied history")
        XCTAssertEqual(session.metadata.totalInputTokens, 50)
        XCTAssertEqual(session.metadata.firstTimestamp, t2)
    }

    func testTraceSkipsCopiesButIndexesTheChatsRecords() async throws {
        let (parent, job) = try writePair()
        let session = try await SessionParser().parse(url: job, sessionId: "child-id", continuationParent: parent)

        XCTAssertEqual(session.copiedRecordUUIDs, ["u1", "a1"])
        XCTAssertEqual(session.ownRecords.compactMap(\.uuid), ["u2", "a2"])

        let trace = try XCTUnwrap(SessionTrace.build(for: session, blockedToolUseIds: [], pricingTable: table))
        XCTAssertEqual(trace.userTurns.count, 1)
        XCTAssertEqual(trace.costPoints.count, 1)
        XCTAssertEqual(trace.userTurns.first?.recordIndex, session.records.firstIndex { $0.uuid == "u2" },
                       "trace marks still index the full record list the chat renders")
    }

    func testToolsSkipCopiedCallsWhileTheChatKeepsThem() async throws {
        func call(_ session: String) -> String {
            """
            {"type":"assistant","uuid":"a1","sessionId":"\(session)","timestamp":"\(t1)","message":{"role":"assistant","id":"msg_A","model":"claude-opus-4-5-20250120","stop_reason":"tool_use","usage":{"input_tokens":100,"output_tokens":200},"content":[{"type":"tool_use","id":"toolu_A","name":"Bash","input":{"command":"ls"}}]}}
            """
        }
        let parent = try write("parent-id", [user("u1", "parent-id", at: t0), call("parent-id")])
        let job = try write("child-id", [user("u1", "child-id", at: t0), call("child-id")] + jobOwnLines.dropFirst())
        let session = try await SessionParser().parse(url: job, sessionId: "child-id", continuationParent: parent)

        XCTAssertEqual(extractToolCalls(from: session).map(\.id), ["toolu_A"],
                       "the chat's blocked-call markers still cover the copied history")
        XCTAssertTrue(extractToolCalls(from: session, ownOnly: true).isEmpty,
                      "the Tools view lists only the job's own calls")
    }

    // MARK: - Cache fingerprint and reconcile

    func testReconcileParsesJobAgainstParentAndRereadsItWhenParentGoes() async throws {
        let (parent, job) = try writePair()
        XCTAssertNotNil(SessionSummaryStore.statIdentity(for: job, continuationParent: parent)?.parentSize,
                        "the watcher fingerprints the parent like reconcile does")

        let store = try SessionSummaryStore(DatabaseQueue())
        let scanner = ProjectScanner(claudeDir: claudeDir, parser: SessionParser(), pricingTable: table)
        let links = ["child-id": parent]
        let first = Upserts()
        _ = await scanner.reconcile(store: store, continuationParents: links, applyDelta: {
            first.summaries += $0.upserts.map(\.summary)
        })
        XCTAssertEqual(first.job()?.totalInputTokens, 50)

        // Cleanup can delete the parent first. Its fingerprint goes with it, so
        // the job is re-read and carries the whole history's spend again.
        try FileManager.default.removeItem(at: parent)
        let second = Upserts()
        _ = await scanner.reconcile(store: store, continuationParents: links, applyDelta: {
            second.summaries += $0.upserts.map(\.summary)
        })
        XCTAssertEqual(second.job()?.totalInputTokens, 150)
    }
}
