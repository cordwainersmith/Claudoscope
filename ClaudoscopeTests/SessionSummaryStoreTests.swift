import XCTest
import GRDB
@testable import Claudoscope

/// The persistent summary cache is a derivative store: these tests pin the
/// three properties that keep it safe. (1) Global-key mismatches wipe it,
/// (2) a hydrated blob is bit-identical to the fresh parse it cached, and
/// (3) corruption degrades to a rebuild, never a crash or stale data.
final class SessionSummaryStoreTests: XCTestCase {

    // MARK: - Helpers

    private func makeStore() throws -> SessionSummaryStore {
        try SessionSummaryStore(DatabaseQueue())
    }

    private let keysA = SessionSummaryStore.GlobalCacheKeys(
        parserVersion: 1,
        pricingKey: "anthropic|global|hash-a",
        tzIdentifier: "Asia/Jerusalem"
    )

    private func minimalSummary(id: String) -> SessionSummary {
        SessionSummary(
            id: id, projectId: "proj", slug: nil, title: id,
            firstTimestamp: "", lastTimestamp: "2026-07-12T10:00:00.000Z",
            messageCount: 1, primaryModel: nil,
            totalInputTokens: 0, totalOutputTokens: 0, totalCacheReadTokens: 0,
            totalCacheCreationTokens: 0, totalCacheCreation5mTokens: 0,
            totalCacheCreation1hTokens: 0, compactionCount: 0, estimatedCost: 0,
            hasError: false, modelBreakdown: [], toolCallCount: 0,
            observability: .empty, isSubagent: false, dailyContributions: []
        )
    }

    private func makeRecord(
        path: String,
        summary: SessionSummary,
        projectDir: String = "proj",
        size: Int64 = 10,
        mtime: Double = 1_000
    ) throws -> SessionSummaryRecord {
        try SessionSummaryRecord.make(
            summary: summary,
            filePath: path,
            projectDir: projectDir,
            identity: SessionSummaryStore.FileIdentity(
                size: size, mtime: mtime, parentSize: nil, parentMtime: nil
            )
        )
    }

    private func writeTempFile(_ lines: [String], name: String = UUID().uuidString) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudoscope-store-\(name).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Schema & meta

    func testFirstOpenSeedsMetaWithoutWipe() async throws {
        let store = try makeStore()
        let wiped = try await store.checkAndApplyGlobalKeys(keysA)
        XCTAssertFalse(wiped, "fresh database seeds keys, nothing to wipe")

        let again = try await store.checkAndApplyGlobalKeys(keysA)
        XCTAssertFalse(again, "matching keys must not wipe")

        let identities = try await store.fetchIdentities()
        XCTAssertTrue(identities.isEmpty)
    }

    func testGlobalKeyMismatchWipesRows() async throws {
        let variants: [(String, SessionSummaryStore.GlobalCacheKeys)] = [
            ("parserVersion", .init(parserVersion: 2, pricingKey: keysA.pricingKey, tzIdentifier: keysA.tzIdentifier)),
            ("pricingKey", .init(parserVersion: keysA.parserVersion, pricingKey: "vertex|global|hash-b", tzIdentifier: keysA.tzIdentifier)),
            ("tzIdentifier", .init(parserVersion: keysA.parserVersion, pricingKey: keysA.pricingKey, tzIdentifier: "UTC")),
        ]
        for (field, changed) in variants {
            let store = try makeStore()
            _ = try await store.checkAndApplyGlobalKeys(keysA)
            try await store.upsert([makeRecord(path: "/tmp/a.jsonl", summary: minimalSummary(id: "a"))])

            let wiped = try await store.checkAndApplyGlobalKeys(changed)
            XCTAssertTrue(wiped, "changed \(field) must wipe rows")
            let after = try await store.fetchIdentities()
            XCTAssertTrue(after.isEmpty, "rows must be gone after \(field) mismatch")
        }
    }

    func testMatchingKeysRetainRows() async throws {
        let store = try makeStore()
        _ = try await store.checkAndApplyGlobalKeys(keysA)
        try await store.upsert([makeRecord(path: "/tmp/a.jsonl", summary: minimalSummary(id: "a"))])

        let wiped = try await store.checkAndApplyGlobalKeys(keysA)
        XCTAssertFalse(wiped)
        let identities = try await store.fetchIdentities()
        XCTAssertEqual(identities.count, 1)
    }

    // MARK: - Upsert / delete / identities

    func testUpsertReplacesByFilePath() async throws {
        let store = try makeStore()
        try await store.upsert([makeRecord(path: "/tmp/a.jsonl", summary: minimalSummary(id: "a"), mtime: 1_000)])
        try await store.upsert([makeRecord(path: "/tmp/a.jsonl", summary: minimalSummary(id: "a"), mtime: 2_000)])

        let identities = try await store.fetchIdentities()
        XCTAssertEqual(identities.count, 1)
        XCTAssertEqual(identities["/tmp/a.jsonl"]?.mtime, 2_000)
    }

    func testDeleteRemovesRowsChunked() async throws {
        let store = try makeStore()
        // 1,200 rows exercises the 500-key IN-list chunking (3 chunks).
        let paths = (0..<1_200).map { "/tmp/bulk-\($0).jsonl" }
        let records = try paths.map { try makeRecord(path: $0, summary: minimalSummary(id: $0)) }
        try await store.upsert(records)

        try await store.delete(filePaths: paths)
        let identities = try await store.fetchIdentities()
        XCTAssertTrue(identities.isEmpty)
    }

    func testParentIdentityColumnsRoundTrip() async throws {
        let store = try makeStore()
        let withParent = SessionSummaryStore.FileIdentity(
            size: 42, mtime: 1_234.5, parentSize: 99, parentMtime: 5_678.25
        )
        try await store.upsert([
            try SessionSummaryRecord.make(
                summary: minimalSummary(id: "fork"),
                filePath: "/tmp/agent-acompact-x.jsonl",
                projectDir: "proj",
                identity: withParent
            ),
        ])

        let identities = try await store.fetchIdentities()
        XCTAssertEqual(identities["/tmp/agent-acompact-x.jsonl"], withParent)
    }

    // MARK: - Hydration

    func testUndecodableBlobReportedAsMiss() async throws {
        let store = try makeStore()
        try await store.upsert([makeRecord(path: "/tmp/good.jsonl", summary: minimalSummary(id: "good"))])
        try await store.upsert([SessionSummaryRecord(
            filePath: "/tmp/bad.jsonl",
            projectDir: "proj",
            sessionId: "bad",
            fileSize: 1,
            fileMtime: 1,
            parentFileSize: nil,
            parentFileMtime: nil,
            isSubagent: false,
            lastTimestamp: "",
            summaryJson: Data("not a summary".utf8)
        )])

        let (rows, undecodable) = try await store.fetchAllForHydration()
        XCTAssertEqual(rows.map(\.summary.id), ["good"])
        XCTAssertEqual(undecodable, ["/tmp/bad.jsonl"])

        // Caller contract: deleting the reported paths turns them into misses.
        try await store.delete(filePaths: undecodable)
        let identities = try await store.fetchIdentities()
        XCTAssertNil(identities["/tmp/bad.jsonl"])
        XCTAssertNotNil(identities["/tmp/good.jsonl"])
    }

    // MARK: - Golden master: fresh parse == hydrated blob

    func testGoldenMasterFreshParseEqualsHydratedBlob() async throws {
        // Rich fixture: a completed stream (intermediate + stop_reason final with
        // cache tiers), a growing-usage orphan on a different day, a compaction
        // boundary, and a user first line for title derivation.
        let lines = [
            #"{"type":"user","uuid":"u0","sessionId":"sess-gold","timestamp":"2026-07-10T09:00:00.000Z","message":{"role":"user","content":"Build the cache layer"}}"#,
            #"{"type":"assistant","uuid":"a1","sessionId":"sess-gold","timestamp":"2026-07-10T09:00:05.000Z","message":{"role":"assistant","id":"msg_done","model":"claude-fable-5","stop_reason":null,"usage":{"input_tokens":10,"output_tokens":20}}}"#,
            #"{"type":"assistant","uuid":"a2","sessionId":"sess-gold","timestamp":"2026-07-10T09:00:09.000Z","message":{"role":"assistant","id":"msg_done","model":"claude-fable-5","stop_reason":"end_turn","usage":{"input_tokens":100,"output_tokens":200,"cache_read_input_tokens":300,"cache_creation_input_tokens":400,"cache_creation":{"ephemeral_5m_input_tokens":250,"ephemeral_1h_input_tokens":150}}}}"#,
            #"{"type":"system","subtype":"compact_boundary","uuid":"c1","sessionId":"sess-gold","timestamp":"2026-07-10T10:00:00.000Z"}"#,
            #"{"type":"assistant","uuid":"a3","sessionId":"sess-gold","timestamp":"2026-07-11T09:00:00.000Z","message":{"role":"assistant","id":"msg_orphan","model":"claude-opus-4-5-20250120","stop_reason":null,"usage":{"input_tokens":50,"output_tokens":10}}}"#,
            #"{"type":"assistant","uuid":"a4","sessionId":"sess-gold","timestamp":"2026-07-11T09:00:03.000Z","message":{"role":"assistant","id":"msg_orphan","model":"claude-opus-4-5-20250120","stop_reason":null,"usage":{"input_tokens":50,"output_tokens":90}}}"#,
        ]
        let url = try writeTempFile(lines, name: "golden")
        defer { try? FileManager.default.removeItem(at: url) }

        let parser = SessionParser()
        let fresh = try await parser.parseMetadata(
            url: url, sessionId: "sess-gold", pricingTable: PricingTables.anthropic
        )

        // Fixture sanity: if a line stops decoding, the round-trip below would
        // still pass while silently testing less. Pin the load-bearing numbers.
        XCTAssertEqual(fresh.totalInputTokens, 150, "final(100) + orphan max(50)")
        XCTAssertEqual(fresh.totalOutputTokens, 290, "final(200) + orphan max(90)")
        XCTAssertEqual(fresh.totalCacheCreationTokens, 400)
        XCTAssertEqual(
            fresh.totalCacheCreation5mTokens + fresh.totalCacheCreation1hTokens, 400,
            "tier split must reconcile with the total whichever decode path ran"
        )
        XCTAssertEqual(fresh.dailyContributions.count, 2, "two distinct local days")
        XCTAssertEqual(fresh.compactionCount, 1)
        XCTAssertEqual(fresh.title, "Build the cache layer")

        // Round-trip through the store.
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let identity = SessionSummaryStore.FileIdentity(
            size: (attrs[.size] as? Int64) ?? 0,
            mtime: (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
            parentSize: nil,
            parentMtime: nil
        )
        let store = try makeStore()
        try await store.upsert([
            try SessionSummaryRecord.make(
                summary: fresh, filePath: url.path, projectDir: "proj-gold", identity: identity
            ),
        ])

        let (rows, undecodable) = try await store.fetchAllForHydration()
        XCTAssertTrue(undecodable.isEmpty)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].projectDir, "proj-gold")
        XCTAssertEqual(rows[0].summary, fresh, "hydrated blob must equal the fresh parse exactly")
    }

    // MARK: - Corruption recovery

    func testCorruptDatabaseFileRecovered() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudoscope-corrupt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("cache.sqlite")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("this is not a sqlite database".utf8).write(to: dbURL)

        let store = SessionSummaryStore.open(at: dbURL)
        let opened = try XCTUnwrap(store, "corrupt file must be deleted and recreated")

        // The recreated store must be empty and fully functional.
        _ = try await opened.checkAndApplyGlobalKeys(keysA)
        try await opened.upsert([makeRecord(path: "/tmp/a.jsonl", summary: minimalSummary(id: "a"))])
        let identities = try await opened.fetchIdentities()
        XCTAssertEqual(identities.count, 1)
    }

    // MARK: - mtime precision

    func testMtimeSurvivesRealColumnRoundTrip() async throws {
        // Real stat, not a synthetic value: covers real-world fractional mtimes.
        let url = try writeTempFile(["{}"], name: "mtime")
        defer { try? FileManager.default.removeItem(at: url) }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = try XCTUnwrap(attrs[.modificationDate] as? Date).timeIntervalSince1970
        let size = try XCTUnwrap(attrs[.size] as? Int64)

        let store = try makeStore()
        try await store.upsert([
            try SessionSummaryRecord.make(
                summary: minimalSummary(id: "m"),
                filePath: url.path,
                projectDir: "proj",
                identity: SessionSummaryStore.FileIdentity(
                    size: size, mtime: mtime, parentSize: nil, parentMtime: nil
                )
            ),
        ])

        let identities = try await store.fetchIdentities()
        let fetched = try XCTUnwrap(identities[url.path])
        XCTAssertEqual(fetched.mtime, mtime, "Double must round-trip the REAL column exactly")
        XCTAssertEqual(fetched.size, size)
    }
}
