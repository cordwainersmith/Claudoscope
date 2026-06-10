import XCTest
@testable import Claudoscope

/// Regression tests for the `/resume` cost-attribution bug: a session resumed on a
/// later day must bill its earlier-day cost to that earlier day, not to "today".
/// Covers the parser's per-day breakdown (and the derived-lump invariant) and the
/// AnalyticsEngine date-window projection that the popover "Today" stat shares.
final class ResumeCostAttributionTests: XCTestCase {

    // Two timestamps four days apart so they land on distinct LOCAL days in any
    // machine timezone.
    private let tsA = "2026-01-01T12:00:00.000Z"
    private let tsB = "2026-01-05T12:00:00.000Z"

    private func writeTempFile(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudoscope-resume-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func billed(
        msgId: String,
        ts: String?,
        input: Int = 1000,
        output: Int = 2000,
        model: String = "claude-opus-4-5-20250120",
        uuid: String = UUID().uuidString
    ) -> String {
        let tsField = ts.map { "\"timestamp\":\"\($0)\"," } ?? ""
        return "{\"type\":\"assistant\",\"uuid\":\"\(uuid)\",\"sessionId\":\"sess-1\",\(tsField)\"message\":{\"role\":\"assistant\",\"id\":\"\(msgId)\",\"stop_reason\":\"end_turn\",\"model\":\"\(model)\",\"usage\":{\"input_tokens\":\(input),\"output_tokens\":\(output),\"service_tier\":\"standard\"}}}"
    }

    private func localKey(_ iso: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: ISO8601.parse(iso)!)
    }

    private func startOfLocalDay(_ iso: String) -> Date {
        Calendar.current.startOfDay(for: ISO8601.parse(iso)!)
    }

    private func parse(_ lines: [String]) async throws -> SessionSummary {
        let url = try writeTempFile(lines)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await SessionParser().parseMetadata(
            url: url, sessionId: "sess-1", pricingTable: PricingTables.anthropic
        )
    }

    // MARK: - Parser: per-day split + derived-lump invariant

    func testPerDaySplitReconcilesWithLump() async throws {
        let s = try await parse([
            billed(msgId: "m1", ts: tsA, input: 1000, output: 2000),
            billed(msgId: "m2", ts: tsB, input: 500, output: 4000),
        ])

        XCTAssertEqual(s.dailyContributions.count, 2)
        XCTAssertEqual(s.dailyContributions.map(\.date), [localKey(tsA), localKey(tsB)],
                       "contributions are keyed by local day, ascending")

        // Invariant: the per-day buckets reproduce every lump field exactly.
        let sumCost = s.dailyContributions.reduce(0.0) { $0 + $1.estimatedCost }
        XCTAssertEqual(sumCost, s.estimatedCost, accuracy: 1e-9)
        XCTAssertEqual(s.dailyContributions.reduce(0) { $0 + $1.inputTokens }, s.totalInputTokens)
        XCTAssertEqual(s.dailyContributions.reduce(0) { $0 + $1.outputTokens }, s.totalOutputTokens)

        for d in s.dailyContributions { XCTAssertGreaterThan(d.estimatedCost, 0) }
    }

    func testDuplicateMessageIdNotDoubleCounted() async throws {
        // Same msg.id re-persisted (Claude Code does this across tool-use turns):
        // must bill once, and the per-day sum must still equal the lump.
        let single = try await parse([billed(msgId: "m1", ts: tsA)])
        let dupd = try await parse([
            billed(msgId: "m1", ts: tsA),
            billed(msgId: "m1", ts: tsA),   // duplicate id, same day
            billed(msgId: "m2", ts: tsB),
        ])

        let dayA = dupd.dailyContributions.first { $0.date == self.localKey(tsA) }!
        XCTAssertEqual(dayA.estimatedCost, single.estimatedCost, accuracy: 1e-9,
                       "the duplicate must not inflate day A")
        let sumCost = dupd.dailyContributions.reduce(0.0) { $0 + $1.estimatedCost }
        XCTAssertEqual(sumCost, dupd.estimatedCost, accuracy: 1e-9)
    }

    func testTimestamplessBillableAttributedToLastSeenDay() async throws {
        // A billable record with no timestamp of its own must still be billed and
        // land in a bucket so the lump stays whole.
        let s = try await parse([
            billed(msgId: "m1", ts: tsA),
            billed(msgId: "m2", ts: nil),   // no timestamp -> last-seen day (A)
        ])
        XCTAssertEqual(s.dailyContributions.count, 1)
        XCTAssertEqual(s.dailyContributions[0].date, localKey(tsA))
        let sumCost = s.dailyContributions.reduce(0.0) { $0 + $1.estimatedCost }
        XCTAssertEqual(sumCost, s.estimatedCost, accuracy: 1e-9)
        XCTAssertGreaterThan(s.totalOutputTokens, 0)
    }

    // MARK: - AnalyticsEngine: date-window projection

    private func analytics(_ s: SessionSummary, from: Date?, to: Date?) -> AnalyticsData {
        let project = Project(id: "proj", name: "Proj", path: "/tmp/proj", sessionCount: 1)
        return AnalyticsEngine.compute(
            sessions: [(session: s, project: project)],
            pricingTable: PricingTables.anthropic,
            from: from, to: to
        )
    }

    func testResumedSessionCountsOnlyInRangeDay() async throws {
        let s = try await parse([
            billed(msgId: "m1", ts: tsA, input: 1000, output: 2000),
            billed(msgId: "m2", ts: tsB, input: 500, output: 4000),
        ])
        let dayBCost = s.dailyContributions.first { $0.date == self.localKey(tsB) }!.estimatedCost

        // Window starting at day B's local midnight = the popover "Today" case.
        let windowed = analytics(s, from: startOfLocalDay(tsB), to: nil)
        XCTAssertEqual(windowed.totalCost, dayBCost, accuracy: 1e-9,
                       "resume must not pull day A's spend into the day-B window")
        XCTAssertEqual(windowed.dailyUsage.count, 1)
        XCTAssertEqual(windowed.dailyUsage.first?.date, localKey(tsB))
        // dailyModelCost must be keyed to day B (not the session's first day).
        XCTAssertFalse(windowed.dailyModelCost.isEmpty)
        XCTAssertTrue(windowed.dailyModelCost.allSatisfy { $0.date == self.localKey(tsB) })
        // Cards reconcile with the corrected headline.
        XCTAssertEqual(windowed.projectCosts.reduce(0.0) { $0 + $1.totalCost }, windowed.totalCost, accuracy: 1e-9)

        // Unbounded range still equals the full lump.
        let all = analytics(s, from: nil, to: nil)
        XCTAssertEqual(all.totalCost, s.estimatedCost, accuracy: 1e-9)
        XCTAssertEqual(all.dailyUsage.count, 2)
    }

    func testCustomRangeUpperBoundIsExclusivePerDay() async throws {
        let s = try await parse([
            billed(msgId: "m1", ts: tsA),
            billed(msgId: "m2", ts: tsB),
        ])
        let dayACost = s.dailyContributions.first { $0.date == self.localKey(tsA) }!.estimatedCost

        // `to` = start of the day after A (the custom range's exclusive next-midnight)
        // must include day A and exclude day B.
        let to = Calendar.current.date(byAdding: .day, value: 1, to: startOfLocalDay(tsA))!
        let windowed = analytics(s, from: startOfLocalDay(tsA), to: to)
        XCTAssertEqual(windowed.totalCost, dayACost, accuracy: 1e-9)
        XCTAssertEqual(windowed.dailyUsage.map(\.date), [localKey(tsA)])
    }

    func testWindowBoundaryIsDayGranular() async throws {
        let s = try await parse([
            billed(msgId: "m1", ts: tsA),
            billed(msgId: "m2", ts: tsB),
        ])
        let dayBCost = s.dailyContributions.first { $0.date == self.localKey(tsB) }!.estimatedCost

        // The from-instant's time-of-day is irrelevant; only its LOCAL day matters.
        // Midday of day B still includes all of day B (a morning contribution is not
        // partially excluded), and day A stays out.
        let middayB = startOfLocalDay(tsB).addingTimeInterval(12 * 3600)
        let windowed = analytics(s, from: middayB, to: nil)
        XCTAssertEqual(windowed.totalCost, dayBCost, accuracy: 1e-9)
        XCTAssertEqual(windowed.dailyUsage.map(\.date), [localKey(tsB)])
    }
}
