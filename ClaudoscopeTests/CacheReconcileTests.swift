import XCTest
import GRDB
@testable import Claudoscope

/// ProjectScanner.reconcile diffs the filesystem against the summary cache and
/// re-parses only changed files. These tests pin the identity semantics: exact
/// (size, mtime) match skips the parse (proven with sentinel blobs the parser
/// could never produce), any mismatch reparses, context-fork subagent files
/// also fingerprint their parent transcript, and rows lose their cache entry
/// when the backing file disappears.
@MainActor
final class CacheReconcileTests: XCTestCase {

    // MARK: - Fixtures

    /// Collects reconcile callbacks; MainActor-isolated like the real consumer.
    @MainActor
    private final class DeltaCollector {
        var upserts: [(projectDir: String, summary: SessionSummary)] = []
        var deletions: [(projectDir: String, sessionId: String)] = []
        var progress: [(processed: Int, total: Int)] = []

        var upsertedIds: [String] { upserts.map(\.summary.id) }
    }

    private var claudeDir: URL!

    override func setUp() {
        super.setUp()
        claudeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudoscope-reconcile-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: claudeDir.appendingPathComponent("projects"), withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: claudeDir)
        super.tearDown()
    }

    private func makeStore() throws -> SessionSummaryStore {
        try SessionSummaryStore(DatabaseQueue())
    }

    private func makeScanner(parser: SessionParser = SessionParser()) -> ProjectScanner {
        ProjectScanner(claudeDir: claudeDir, parser: parser, pricingTable: PricingTables.anthropic)
    }

    /// `sessionId` must match the transcript's own session id for top-level
    /// files: a mismatching id makes the parser treat the file as a
    /// continuation and skip every record. Sidechain (subagent) records
    /// bypass that branch, so the context-fork fixtures keep the default.
    private func assistantRecord(uuid: String, msgId: String, sessionId: String = "parent-uuid", input: Int = 100, output: Int = 200, sidechain: Bool = false) -> String {
        let sc = sidechain ? ",\"isSidechain\":true" : ""
        return """
        {"type":"assistant","uuid":"\(uuid)","sessionId":"\(sessionId)"\(sc),"timestamp":"2026-07-10T10:00:00.000Z","message":{"role":"assistant","id":"\(msgId)","model":"claude-opus-4-5-20250120","stop_reason":"end_turn","usage":{"input_tokens":\(input),"output_tokens":\(output)}}}
        """
    }

    @discardableResult
    private func writeSession(
        project: String, id: String, lines: [String], mtime: Date? = nil
    ) throws -> URL {
        let dir = claudeDir.appendingPathComponent("projects").appendingPathComponent(project)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(id).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        if let mtime {
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        }
        return url
    }

    @discardableResult
    private func writeSubagent(
        project: String, parentId: String, fileName: String, lines: [String], mtime: Date? = nil
    ) throws -> URL {
        let dir = claudeDir.appendingPathComponent("projects").appendingPathComponent(project)
            .appendingPathComponent(parentId).appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(fileName)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        if let mtime {
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        }
        return url
    }

    /// Runs reconcile and returns the collector plus liveKeys.
    @discardableResult
    private func runReconcile(
        _ scanner: ProjectScanner, store: SessionSummaryStore?
    ) async -> (collector: DeltaCollector, liveKeys: Set<ProjectScanner.LiveEntryKey>) {
        let collector = DeltaCollector()
        let liveKeys = await scanner.reconcile(
            store: store,
            onProgress: { processed, total in collector.progress.append((processed, total)) },
            applyDelta: { delta in
                collector.upserts.append(contentsOf: delta.upserts)
                collector.deletions.append(contentsOf: delta.deletions)
            }
        )
        return (collector, liveKeys)
    }

    private let d1 = Date(timeIntervalSince1970: 1_752_000_000)
    private let d2 = Date(timeIntervalSince1970: 1_752_000_100)

    // MARK: - Skip / reparse semantics

    func testUnchangedFileSkipsReparse() async throws {
        let url = try writeSession(project: "proj-a", id: "s1",
                                   lines: [assistantRecord(uuid: "u1", msgId: "m1", sessionId: "s1")], mtime: d1)
        let store = try makeStore()
        let scanner = makeScanner()

        // First pass parses and caches.
        let first = await runReconcile(scanner, store: store)
        XCTAssertEqual(first.collector.upsertedIds, ["s1"])

        // Plant a sentinel blob the parser could never produce, with the SAME
        // identity: if the second pass emits real numbers, it reparsed.
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let identity = SessionSummaryStore.FileIdentity(
            size: try XCTUnwrap(attrs[.size] as? Int64),
            mtime: try XCTUnwrap(attrs[.modificationDate] as? Date).timeIntervalSince1970,
            parentSize: nil, parentMtime: nil
        )
        let sentinel = SessionSummary(
            id: "s1", projectId: "proj-a", slug: nil, title: "sentinel",
            firstTimestamp: "", lastTimestamp: "2026-07-10T10:00:00.000Z",
            messageCount: 777_777, primaryModel: nil,
            totalInputTokens: 777_777, totalOutputTokens: 0, totalCacheReadTokens: 0,
            totalCacheCreationTokens: 0, totalCacheCreation5mTokens: 0,
            totalCacheCreation1hTokens: 0, compactionCount: 0, estimatedCost: 0,
            hasError: false, modelBreakdown: [], toolCallCount: 0,
            observability: .empty, isSubagent: false, dailyContributions: []
        )
        try await store.upsert([
            try SessionSummaryRecord.make(summary: sentinel, filePath: url.path, projectDir: "proj-a", identity: identity),
        ])

        let second = await runReconcile(scanner, store: store)
        XCTAssertTrue(second.collector.upserts.isEmpty, "unchanged file must not reparse")
        XCTAssertTrue(second.collector.deletions.isEmpty)

        let (rows, _) = try await store.fetchAllForHydration()
        XCTAssertEqual(rows.first?.summary.totalInputTokens, 777_777,
                       "sentinel must survive: proof no reparse touched the row")
    }

    func testStaleFileViaSizeChangeReparses() async throws {
        try writeSession(project: "proj-a", id: "s1",
                         lines: [assistantRecord(uuid: "u1", msgId: "m1", sessionId: "s1")], mtime: d1)
        let store = try makeStore()
        let scanner = makeScanner()
        _ = await runReconcile(scanner, store: store)

        // Append a second record (size + mtime change).
        try writeSession(project: "proj-a", id: "s1", lines: [
            assistantRecord(uuid: "u1", msgId: "m1", sessionId: "s1"),
            assistantRecord(uuid: "u2", msgId: "m2", sessionId: "s1", input: 50, output: 75),
        ], mtime: d2)

        let second = await runReconcile(scanner, store: store)
        XCTAssertEqual(second.collector.upsertedIds, ["s1"])
        XCTAssertEqual(second.collector.upserts.first?.summary.totalInputTokens, 150)
    }

    func testStaleFileViaMtimeOnlyTouchReparses() async throws {
        let url = try writeSession(project: "proj-a", id: "s1",
                                   lines: [assistantRecord(uuid: "u1", msgId: "m1", sessionId: "s1")], mtime: d1)
        let store = try makeStore()
        let scanner = makeScanner()
        _ = await runReconcile(scanner, store: store)

        // Same bytes, new mtime: must still reparse (equal-size rewrite case).
        try FileManager.default.setAttributes([.modificationDate: d2], ofItemAtPath: url.path)

        let second = await runReconcile(scanner, store: store)
        XCTAssertEqual(second.collector.upsertedIds, ["s1"], "mtime-only change must reparse")
    }

    func testNewFileParsedAndInserted() async throws {
        try writeSession(project: "proj-a", id: "s1",
                         lines: [assistantRecord(uuid: "u1", msgId: "m1", sessionId: "s1")], mtime: d1)
        let store = try makeStore()
        let scanner = makeScanner()
        _ = await runReconcile(scanner, store: store)

        try writeSession(project: "proj-a", id: "s2",
                         lines: [assistantRecord(uuid: "u2", msgId: "m2", sessionId: "s2")], mtime: d2)

        let second = await runReconcile(scanner, store: store)
        XCTAssertEqual(second.collector.upsertedIds, ["s2"], "only the new file parses")
        let identities = try await store.fetchIdentities()
        XCTAssertEqual(identities.count, 2)
    }

    func testDeletedFileRowRemoved() async throws {
        let url = try writeSession(project: "proj-a", id: "s1",
                                   lines: [assistantRecord(uuid: "u1", msgId: "m1", sessionId: "s1")], mtime: d1)
        try writeSession(project: "proj-a", id: "s2",
                         lines: [assistantRecord(uuid: "u2", msgId: "m2", sessionId: "s2")], mtime: d1)
        let store = try makeStore()
        let scanner = makeScanner()
        _ = await runReconcile(scanner, store: store)

        try FileManager.default.removeItem(at: url)

        let second = await runReconcile(scanner, store: store)
        XCTAssertEqual(second.collector.deletions.map(\.sessionId), ["s1"])
        XCTAssertEqual(second.collector.deletions.first?.projectDir, "proj-a")
        XCTAssertFalse(second.liveKeys.contains(.init(projectDir: "proj-a", sessionId: "s1")))

        let identities = try await store.fetchIdentities()
        XCTAssertEqual(identities.count, 1, "deleted file's row must be gone")
    }

    func testProgressCountsOnlyChangedFiles() async throws {
        for i in 0..<3 {
            try writeSession(project: "proj-a", id: "keep-\(i)",
                             lines: [assistantRecord(uuid: "u\(i)", msgId: "m\(i)", sessionId: "keep-\(i)")], mtime: d1)
        }
        let store = try makeStore()
        let scanner = makeScanner()
        _ = await runReconcile(scanner, store: store)

        try writeSession(project: "proj-a", id: "keep-0", lines: [
            assistantRecord(uuid: "u0", msgId: "m0", sessionId: "keep-0"),
            assistantRecord(uuid: "ux", msgId: "mx", sessionId: "keep-0"),
        ], mtime: d2)

        let second = await runReconcile(scanner, store: store)
        XCTAssertEqual(second.collector.progress.first?.total, 1,
                       "progress total counts changed files only, not the corpus")
        XCTAssertEqual(second.collector.upsertedIds, ["keep-0"])
    }

    // MARK: - Context-fork parent fingerprinting

    func testContextForkParentAppendInvalidatesChild() async throws {
        let parentLines = [
            assistantRecord(uuid: "p1", msgId: "msg_A"),
            assistantRecord(uuid: "p2", msgId: "msg_B"),
        ]
        let subLines = [
            assistantRecord(uuid: "s1", msgId: "msg_A", sidechain: true),
            assistantRecord(uuid: "s2", msgId: "msg_B", sidechain: true),
            assistantRecord(uuid: "s3", msgId: "msg_C", input: 50, output: 75, sidechain: true),
        ]
        try writeSession(project: "proj-a", id: "parent-uuid", lines: parentLines, mtime: d1)
        try writeSubagent(project: "proj-a", parentId: "parent-uuid",
                          fileName: "agent-acompact-abc.jsonl", lines: subLines, mtime: d1)
        let store = try makeStore()
        let scanner = makeScanner()

        let first = await runReconcile(scanner, store: store)
        let firstChild = first.collector.upserts.first { $0.summary.isSubagent }
        XCTAssertEqual(firstChild?.summary.totalInputTokens, 50, "parent has A,B: only C bills")

        // Parent now also contains C; the child file itself is untouched, but
        // its fingerprint includes the parent, so it must reparse to 0.
        try writeSession(project: "proj-a", id: "parent-uuid", lines: parentLines + [
            assistantRecord(uuid: "p3", msgId: "msg_C", input: 50, output: 75),
        ], mtime: d2)

        let second = await runReconcile(scanner, store: store)
        let ids = second.collector.upsertedIds
        XCTAssertTrue(ids.contains("parent-uuid"), "parent changed, parent reparses")
        XCTAssertTrue(ids.contains("agent-acompact-abc"), "child must reparse on parent change")
        let secondChild = second.collector.upserts.first { $0.summary.isSubagent }
        XCTAssertEqual(secondChild?.summary.totalInputTokens, 0,
                       "v2 parent replays everything: child bills nothing")
    }

    func testContextForkParentAbsentStableWhileAbsentThenInvalidatesWhenItAppears() async throws {
        let subLines = [
            assistantRecord(uuid: "s1", msgId: "msg_A", sidechain: true),
            assistantRecord(uuid: "s2", msgId: "msg_B", sidechain: true),
            assistantRecord(uuid: "s3", msgId: "msg_C", input: 50, output: 75, sidechain: true),
        ]
        try writeSubagent(project: "proj-a", parentId: "parent-uuid",
                          fileName: "agent-acompact-abc.jsonl", lines: subLines, mtime: d1)
        let store = try makeStore()
        let scanner = makeScanner()

        let first = await runReconcile(scanner, store: store)
        XCTAssertEqual(first.collector.upserts.first?.summary.totalInputTokens, 250,
                       "no parent on disk: bill everything")

        let second = await runReconcile(scanner, store: store)
        XCTAssertTrue(second.collector.upserts.isEmpty,
                      "parent still absent: NULL == NULL, row stays valid")

        // Parent appears: nil fingerprint no longer matches, child reparses.
        try writeSession(project: "proj-a", id: "parent-uuid", lines: [
            assistantRecord(uuid: "p1", msgId: "msg_A"),
            assistantRecord(uuid: "p2", msgId: "msg_B"),
        ], mtime: d2)

        let third = await runReconcile(scanner, store: store)
        XCTAssertTrue(third.collector.upsertedIds.contains("agent-acompact-abc"))
        let child = third.collector.upserts.first { $0.summary.isSubagent }
        XCTAssertEqual(child?.summary.totalInputTokens, 50, "parent knows A,B now: only C bills")
    }

    func testPlainAgentFileIgnoresParentChanges() async throws {
        try writeSession(project: "proj-a", id: "parent-uuid",
                         lines: [assistantRecord(uuid: "p1", msgId: "msg_A")], mtime: d1)
        try writeSubagent(project: "proj-a", parentId: "parent-uuid",
                          fileName: "agent-deadbeef.jsonl",
                          lines: [assistantRecord(uuid: "s1", msgId: "msg_X", sidechain: true)], mtime: d1)
        let store = try makeStore()
        let scanner = makeScanner()
        _ = await runReconcile(scanner, store: store)

        // Touch the parent only.
        try writeSession(project: "proj-a", id: "parent-uuid", lines: [
            assistantRecord(uuid: "p1", msgId: "msg_A"),
            assistantRecord(uuid: "p2", msgId: "msg_B"),
        ], mtime: d2)

        let second = await runReconcile(scanner, store: store)
        XCTAssertEqual(second.collector.upsertedIds, ["parent-uuid"],
                       "plain agent files carry no parent fingerprint: only the parent reparses")
    }

    // MARK: - Edge cases

    func testEmptyFileCachedAndSkippedNextPass() async throws {
        try writeSession(project: "proj-a", id: "empty", lines: [], mtime: d1)
        let store = try makeStore()
        let scanner = makeScanner()

        let first = await runReconcile(scanner, store: store)
        XCTAssertEqual(first.collector.upsertedIds, ["empty"])
        XCTAssertEqual(first.collector.upserts.first?.summary.totalInputTokens, 0)

        let second = await runReconcile(scanner, store: store)
        XCTAssertTrue(second.collector.upserts.isEmpty, "empty file is cached like any other")
    }

    func testNilStoreFallsBackToFullParse() async throws {
        try writeSession(project: "proj-a", id: "s1",
                         lines: [assistantRecord(uuid: "u1", msgId: "m1", sessionId: "s1")], mtime: d1)
        try writeSession(project: "proj-b", id: "s2",
                         lines: [assistantRecord(uuid: "u2", msgId: "m2", sessionId: "s2")], mtime: d1)
        let scanner = makeScanner()

        let first = await runReconcile(scanner, store: nil)
        XCTAssertEqual(Set(first.collector.upsertedIds), ["s1", "s2"], "nil store: everything parses")

        // And again: still a full parse, nothing is silently cached anywhere.
        let second = await runReconcile(scanner, store: nil)
        XCTAssertEqual(Set(second.collector.upsertedIds), ["s1", "s2"])
    }

    func testLiveKeysCoverAllFilesIncludingSubagents() async throws {
        try writeSession(project: "proj-a", id: "s1",
                         lines: [assistantRecord(uuid: "u1", msgId: "m1", sessionId: "s1")], mtime: d1)
        try writeSubagent(project: "proj-a", parentId: "s1",
                          fileName: "agent-deadbeef.jsonl",
                          lines: [assistantRecord(uuid: "s1r", msgId: "m2", sidechain: true)], mtime: d1)
        try writeSession(project: "proj-b", id: "s3",
                         lines: [assistantRecord(uuid: "u3", msgId: "m3", sessionId: "s3")], mtime: d1)
        let scanner = makeScanner()

        let (_, liveKeys) = await runReconcile(scanner, store: nil)
        XCTAssertEqual(liveKeys, [
            .init(projectDir: "proj-a", sessionId: "s1"),
            .init(projectDir: "proj-a", sessionId: "agent-deadbeef"),
            .init(projectDir: "proj-b", sessionId: "s3"),
        ])
    }
}
