import XCTest
@testable import Claudoscope

/// Tests for pricing-family support: family detection, the three pricing
/// tables, the cost-estimation path, and end-to-end session parses. Covers
/// Claude Fable 5 (`claude-fable-5`) and Claude Sonnet 5 (`claude-sonnet-5`).
final class PricingFamilyTests: XCTestCase {

    /// A day for models whose rate does not vary by date. Named so the dated
    /// Sonnet 5 assertions below read as deliberate rather than incidental.
    private let anyDay = "2026-07-29"

    // MARK: - Family detection

    func testFableModelResolvesToFableFamily() {
        XCTAssertEqual(getModelFamily("claude-fable-5"), "fable")
    }

    func testOpus48StillResolvesToOpus() {
        // Regression guard: the new fable branch must not disturb existing detection.
        XCTAssertEqual(getModelFamily("claude-opus-4-8"), "opus")
    }

    // MARK: - Pricing tables

    func testFableAnthropicPricing() {
        let p = getModelPricing("claude-fable-5", table: PricingTables.anthropic, on: anyDay)
        XCTAssertFalse(p.isUnknown)
        XCTAssertEqual(p.input, 10.0, accuracy: 1e-9)
        XCTAssertEqual(p.output, 50.0, accuracy: 1e-9)
        XCTAssertEqual(p.cacheRead, 1.0, accuracy: 1e-9)
        XCTAssertEqual(p.cacheCreation5m, 12.5, accuracy: 1e-9)
        XCTAssertEqual(p.cacheCreation1h, 20.0, accuracy: 1e-9)
    }

    func testFableVertexRegionalPricing() {
        // Guards the 1.1x regional row against a transcription error.
        let p = getModelPricing("claude-fable-5", table: PricingTables.vertexRegional, on: anyDay)
        XCTAssertEqual(p.input, 11.0, accuracy: 1e-9)
        XCTAssertEqual(p.output, 55.0, accuracy: 1e-9)
    }

    func testOpusPricingUnchanged() {
        let p = getModelPricing("claude-opus-4-8", table: PricingTables.anthropic, on: anyDay)
        XCTAssertEqual(p.input, 5.0, accuracy: 1e-9)
        XCTAssertEqual(p.output, 25.0, accuracy: 1e-9)
    }

    // MARK: - Cost estimation

    func testFableCostEstimateEndToEnd() {
        // 1M input + 1M output at $10/$50 = $60.
        let cost = estimateCostFromTokens(
            model: "claude-fable-5",
            inputTokens: 1_000_000,
            outputTokens: 1_000_000,
            cacheReadTokens: 0,
            cacheCreation5mTokens: 0,
            cacheCreation1hTokens: 0,
            table: PricingTables.anthropic,
            on: anyDay
        )
        XCTAssertEqual(cost, 60.0, accuracy: 1e-9)
    }

    // MARK: - End-to-end parse

    private func writeTempFile(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudoscope-fable-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Parsing a real `claude-fable-5` assistant record must produce a non-zero
    /// cost at the Fable rate (the family -> breakdown -> cost chain), not the
    /// $0 an "unknown" family would yield before this support was added.
    func testFableSessionParsesAtFableRate() async throws {
        let parser = SessionParser()
        let rec = "{\"type\":\"assistant\",\"uuid\":\"u1\",\"sessionId\":\"sess-1\",\"timestamp\":\"2026-04-26T10:00:00.000Z\",\"message\":{\"role\":\"assistant\",\"id\":\"m1\",\"stop_reason\":\"end_turn\",\"model\":\"claude-fable-5\",\"usage\":{\"input_tokens\":1000,\"output_tokens\":2000,\"service_tier\":\"standard\"}}}"
        let url = try writeTempFile([rec])
        defer { try? FileManager.default.removeItem(at: url) }

        let s = try await parser.parseMetadata(url: url, sessionId: "sess-1", pricingTable: PricingTables.anthropic)
        XCTAssertGreaterThan(s.estimatedCost, 0)
        // 1000 input * $10/MTok + 2000 output * $50/MTok = 0.01 + 0.10 = 0.11
        XCTAssertEqual(s.estimatedCost, 0.11, accuracy: 1e-9)
    }

    // MARK: - Opus 5 and legacy-allowlist detection

    // Family detection is an explicit allowlist of the pre-4.5 generations, so an
    // unrecognized id resolves to the current rate. The inverse (a version match
    // that fell through to the legacy $15/$75 row) is what mispriced Opus 5 at 3x.

    func testOpus5ResolvesToOpusFamily() {
        XCTAssertEqual(getModelFamily("claude-opus-5"), "opus")
    }

    func testOpus5LongContextVariantResolvesToOpusFamily() {
        XCTAssertEqual(getModelFamily("claude-opus-5[1m]"), "opus")
    }

    func testUnrecognizedOpusIDsFailSafeToCurrentRate() {
        // The regression guard for the whole change: ids that do not exist yet must
        // never inherit legacy pricing just because detection failed to parse them.
        XCTAssertEqual(getModelFamily("claude-opus-6"), "opus")
        XCTAssertEqual(getModelFamily("claude-opus-7-2"), "opus")
        XCTAssertEqual(getModelFamily("claude-opus-next"), "opus")
    }

    func testLegacyOpusIDsResolveToOpus4Family() {
        XCTAssertEqual(getModelFamily("claude-3-opus-20240229"), "opus4")
        XCTAssertEqual(getModelFamily("claude-opus-4-0"), "opus4")
        XCTAssertEqual(getModelFamily("claude-opus-4-1"), "opus4")
    }

    func testModernOpusIDsResolveToOpusFamily() {
        XCTAssertEqual(getModelFamily("claude-opus-4-5-20251101"), "opus")
        XCTAssertEqual(getModelFamily("claude-opus-4-6"), "opus")
        XCTAssertEqual(getModelFamily("claude-opus-4-7"), "opus")
    }

    // MARK: - Haiku legacy allowlist

    // Haiku carries the same failure mode: a future `claude-haiku-5` would have
    // priced at the $0.25 `haiku3` row under version-based detection.

    func testLegacyHaikuIDsResolveToHaiku3Family() {
        XCTAssertEqual(getModelFamily("claude-3-haiku-20240307"), "haiku3")
        XCTAssertEqual(getModelFamily("claude-3-5-haiku-20241022"), "haiku3")
    }

    func testModernAndUnrecognizedHaikuIDsResolveToHaikuFamily() {
        XCTAssertEqual(getModelFamily("claude-haiku-4-5-20251001"), "haiku")
        XCTAssertEqual(getModelFamily("claude-haiku-5"), "haiku")
    }

    func testOpus5AnthropicPricing() {
        let p = getModelPricing("claude-opus-5", table: PricingTables.anthropic, on: anyDay)
        XCTAssertEqual(p.input, 5.0, accuracy: 1e-9)
        XCTAssertEqual(p.output, 25.0, accuracy: 1e-9)
        XCTAssertEqual(p.cacheRead, 0.50, accuracy: 1e-9)
    }

    func testOpus5SessionParsesAtOpusRate() async throws {
        let parser = SessionParser()
        let rec = "{\"type\":\"assistant\",\"uuid\":\"u1\",\"sessionId\":\"sess-1\",\"timestamp\":\"2026-07-26T10:00:00.000Z\",\"message\":{\"role\":\"assistant\",\"id\":\"m1\",\"stop_reason\":\"end_turn\",\"model\":\"claude-opus-5\",\"usage\":{\"input_tokens\":1000,\"output_tokens\":2000,\"service_tier\":\"standard\"}}}"
        let url = try writeTempFile([rec])
        defer { try? FileManager.default.removeItem(at: url) }

        let s = try await parser.parseMetadata(url: url, sessionId: "sess-1", pricingTable: PricingTables.anthropic)
        // 1000 input * $5/MTok + 2000 output * $25/MTok = 0.005 + 0.050 = 0.055
        XCTAssertEqual(s.estimatedCost, 0.055, accuracy: 1e-9)
    }

    // MARK: - Sonnet 5 rate split

    // Sonnet 5 bills $2/$10 where Sonnet 4.5/4.6 bill $3/$15, so the rate is a
    // property of the id, not of the family. Billing it at the flat sonnet row
    // overcharged every Sonnet 5 token by exactly 1.5x. The `sonnet5` table row is a
    // pricing key only — the family must stay "sonnet", because that string is also a
    // UI label, a persisted per-day map key, and an analytics aggregation key.

    func testSonnet5ResolvesToSonnetFamily() {
        // Must NOT become "sonnet5": that would render as "Sonnet5" in the UI and
        // fork a mixed Sonnet 4.5 / Sonnet 5 session into two rows in every breakdown.
        XCTAssertEqual(getModelFamily("claude-sonnet-5"), "sonnet")
    }

    func testSonnet5AnthropicPricing() {
        let p = getModelPricing("claude-sonnet-5", table: PricingTables.anthropic, on: anyDay)
        XCTAssertFalse(p.isUnknown)
        XCTAssertEqual(p.input, 2.0, accuracy: 1e-9)
        XCTAssertEqual(p.output, 10.0, accuracy: 1e-9)
        XCTAssertEqual(p.cacheRead, 0.20, accuracy: 1e-9)
        XCTAssertEqual(p.cacheCreation5m, 2.50, accuracy: 1e-9)
        XCTAssertEqual(p.cacheCreation1h, 4.0, accuracy: 1e-9)
    }

    /// The regression guard for the cancelled increase. Anthropic announced $2/$10 as
    /// introductory pricing through 2026-08-31, then made it the standard price and
    /// called off the 2026-09-01 rise to $3/$15. A cutoff left in the table would
    /// overbill every Sonnet 5 message from September on by 50%.
    func testSonnet5RateDoesNotExpire() {
        for day in ["2026-08-31", "2026-09-01", "2027-06-01"] {
            let p = getModelPricing("claude-sonnet-5", table: PricingTables.anthropic, on: day)
            XCTAssertEqual(p.input, 2.0, accuracy: 1e-9, "on \(day)")
            XCTAssertEqual(p.output, 10.0, accuracy: 1e-9, "on \(day)")
        }
    }

    func testSonnet5VertexRegionalPricing() {
        let p = getModelPricing("claude-sonnet-5", table: PricingTables.vertexRegional, on: anyDay)
        XCTAssertEqual(p.input, 2.20, accuracy: 1e-9)
        XCTAssertEqual(p.output, 11.0, accuracy: 1e-9)
    }

    func testOlderSonnetsKeepTheStandardRate() {
        // The split row is keyed on the Sonnet 5 marker, not the family, so Sonnet 4.5
        // and 4.6 still bill $3/$15.
        for model in ["claude-sonnet-4-5", "claude-sonnet-4-6"] {
            let p = getModelPricing(model, table: PricingTables.anthropic, on: anyDay)
            XCTAssertEqual(p.input, 3.0, accuracy: 1e-9, model)
            XCTAssertEqual(p.output, 15.0, accuracy: 1e-9, model)
        }
    }

    /// End-to-end: a real `claude-sonnet-5` assistant record must price at $2/$10 via
    /// the family -> breakdown -> cost chain.
    func testSonnet5SessionParsesAtSonnet5Rate() async throws {
        let parser = SessionParser()
        let rec = "{\"type\":\"assistant\",\"uuid\":\"u1\",\"sessionId\":\"sess-1\",\"timestamp\":\"2026-07-06T10:00:00.000Z\",\"message\":{\"role\":\"assistant\",\"id\":\"m1\",\"stop_reason\":\"end_turn\",\"model\":\"claude-sonnet-5\",\"usage\":{\"input_tokens\":1000,\"output_tokens\":2000,\"service_tier\":\"standard\"}}}"
        let url = try writeTempFile([rec])
        defer { try? FileManager.default.removeItem(at: url) }

        let s = try await parser.parseMetadata(url: url, sessionId: "sess-1", pricingTable: PricingTables.anthropic)
        XCTAssertGreaterThan(s.estimatedCost, 0)
        // 1000 input * $2/MTok + 2000 output * $10/MTok = 0.002 + 0.020 = 0.022
        XCTAssertEqual(s.estimatedCost, 0.022, accuracy: 1e-9)
    }

    /// Pricing is resolved per message date so a session spanning midnight still bills
    /// each day into its own `dailyContributions` bucket. No rate window is open, so
    /// both days cost the same; the split itself is what this guards.
    func testSessionSpanningMidnightSplitsCostAcrossDays() async throws {
        let parser = SessionParser()
        func record(_ uuid: String, _ msgId: String, _ utcTimestamp: String) -> String {
            "{\"type\":\"assistant\",\"uuid\":\"\(uuid)\",\"sessionId\":\"sess-1\",\"timestamp\":\"\(utcTimestamp)\",\"message\":{\"role\":\"assistant\",\"id\":\"\(msgId)\",\"stop_reason\":\"end_turn\",\"model\":\"claude-sonnet-5\",\"usage\":{\"input_tokens\":1000,\"output_tokens\":2000,\"service_tier\":\"standard\"}}}"
        }
        // Midday UTC so both records land on the intended LOCAL day in any timezone
        // the suite runs in.
        let url = try writeTempFile([
            record("u1", "m1", "2026-08-31T12:00:00.000Z"),
            record("u2", "m2", "2026-09-01T12:00:00.000Z"),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let s = try await parser.parseMetadata(url: url, sessionId: "sess-1", pricingTable: PricingTables.anthropic)
        XCTAssertEqual(s.estimatedCost, 0.044, accuracy: 1e-9)

        let byDay = Dictionary(uniqueKeysWithValues: s.dailyContributions.map { ($0.date, $0.estimatedCost) })
        XCTAssertEqual(try XCTUnwrap(byDay["2026-08-31"]), 0.022, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(byDay["2026-09-01"]), 0.022, accuracy: 1e-9)
    }

    // MARK: - Mythos 5

    // Mythos 5 shipped in limited availability at the Fable 5 rate. Before it was
    // added here its id fell past every family branch to "unknown", which prices at
    // zero — a silent undercount rather than a visible error.

    func testMythosResolvesToMythosFamily() {
        XCTAssertEqual(getModelFamily("claude-mythos-5"), "mythos")
        XCTAssertEqual(getModelFamily("claude-mythos"), "mythos")
    }

    func testMythosAnthropicPricing() {
        let p = getModelPricing("claude-mythos-5", table: PricingTables.anthropic, on: anyDay)
        XCTAssertFalse(p.isUnknown)
        XCTAssertEqual(p.input, 10.0, accuracy: 1e-9)
        XCTAssertEqual(p.output, 50.0, accuracy: 1e-9)
        XCTAssertEqual(p.cacheRead, 1.0, accuracy: 1e-9)
        XCTAssertEqual(p.cacheCreation5m, 12.5, accuracy: 1e-9)
        XCTAssertEqual(p.cacheCreation1h, 20.0, accuracy: 1e-9)
    }

    func testMythosPricedOnEveryTable() {
        for (name, table) in [
            ("anthropic", PricingTables.anthropic),
            ("vertexGlobal", PricingTables.vertexGlobal),
            ("vertexRegional", PricingTables.vertexRegional),
        ] {
            XCTAssertFalse(
                getModelPricing("claude-mythos-5", table: table, on: anyDay).isUnknown,
                "mythos missing from the \(name) table"
            )
        }
    }

    // MARK: - Haiku 3.5 rate split

    // Haiku 3.5 is $0.80/$4; Haiku 3 is $0.25/$1.25. Both ids share the "haiku3"
    // legacy family, so the difference lives in the pricing key, not the family.

    func testHaiku35PricesAboveHaiku3() {
        let h35 = getModelPricing("claude-3-5-haiku-20241022", table: PricingTables.anthropic, on: anyDay)
        XCTAssertEqual(h35.input, 0.80, accuracy: 1e-9)
        XCTAssertEqual(h35.output, 4.0, accuracy: 1e-9)
        XCTAssertEqual(h35.cacheRead, 0.08, accuracy: 1e-9)

        let h3 = getModelPricing("claude-3-haiku-20240307", table: PricingTables.anthropic, on: anyDay)
        XCTAssertEqual(h3.input, 0.25, accuracy: 1e-9)
        XCTAssertEqual(h3.output, 1.25, accuracy: 1e-9)
    }

    func testHaiku35KeepsTheHaiku3FamilyLabel() {
        // Same reasoning as sonnet5: a rate split must not fork the UI/analytics key.
        XCTAssertEqual(getModelFamily("claude-3-5-haiku-20241022"), "haiku3")
    }

    // MARK: - Unpriced models

    /// An id no table knows must resolve to `isUnknown` so the UI can flag it. The
    /// failure mode this guards is the quiet one: cost 0 with no indication that a
    /// model went unpriced.
    func testUnrecognizedModelIsFlaggedNotSilentlyFree() {
        let p = getModelPricing("claude-zzz-9", table: PricingTables.anthropic, on: anyDay)
        XCTAssertTrue(p.isUnknown)
        XCTAssertEqual(getModelFamily("claude-zzz-9"), "unknown")

        let cost = estimateCostFromTokens(
            model: "claude-zzz-9",
            inputTokens: 1_000_000,
            outputTokens: 1_000_000,
            cacheReadTokens: 0,
            cacheCreation5mTokens: 0,
            cacheCreation1hTokens: 0,
            table: PricingTables.anthropic,
            on: anyDay
        )
        XCTAssertEqual(cost, 0, accuracy: 1e-9)
    }

    /// End-to-end: an unpriced model must reach `AnalyticsData.unpricedModels` by id.
    /// Analytics drops the "unknown" family from `modelUsage`, so before this the
    /// model contributed nothing to cost AND nothing to the distribution — a session
    /// that ran entirely on it looked like it had never happened.
    func testUnpricedModelReachesAnalytics() async throws {
        let parser = SessionParser()
        let rec = "{\"type\":\"assistant\",\"uuid\":\"u1\",\"sessionId\":\"sess-1\",\"timestamp\":\"2026-07-06T12:00:00.000Z\",\"message\":{\"role\":\"assistant\",\"id\":\"m1\",\"stop_reason\":\"end_turn\",\"model\":\"claude-zzz-9\",\"usage\":{\"input_tokens\":1000,\"output_tokens\":2000,\"service_tier\":\"standard\"}}}"
        let url = try writeTempFile([rec])
        defer { try? FileManager.default.removeItem(at: url) }

        let s = try await parser.parseMetadata(url: url, sessionId: "sess-1", pricingTable: PricingTables.anthropic)
        let project = Project(id: "proj", name: "Proj", path: "/tmp/proj", sessionCount: 1)
        let data = AnalyticsEngine.compute(
            sessions: [(session: s, project: project)],
            pricingTable: PricingTables.anthropic
        )

        XCTAssertEqual(data.unpricedModels, ["claude-zzz-9"])
        XCTAssertEqual(data.totalCost, 0, accuracy: 1e-9)
        XCTAssertTrue(data.modelUsage.isEmpty, "the unknown family stays out of the distribution")
    }

    func testPricedModelLeavesUnpricedListEmpty() async throws {
        let parser = SessionParser()
        let rec = "{\"type\":\"assistant\",\"uuid\":\"u1\",\"sessionId\":\"sess-1\",\"timestamp\":\"2026-07-06T12:00:00.000Z\",\"message\":{\"role\":\"assistant\",\"id\":\"m1\",\"stop_reason\":\"end_turn\",\"model\":\"claude-opus-5\",\"usage\":{\"input_tokens\":1000,\"output_tokens\":2000,\"service_tier\":\"standard\"}}}"
        let url = try writeTempFile([rec])
        defer { try? FileManager.default.removeItem(at: url) }

        let s = try await parser.parseMetadata(url: url, sessionId: "sess-1", pricingTable: PricingTables.anthropic)
        let project = Project(id: "proj", name: "Proj", path: "/tmp/proj", sessionCount: 1)
        let data = AnalyticsEngine.compute(
            sessions: [(session: s, project: project)],
            pricingTable: PricingTables.anthropic
        )

        XCTAssertTrue(data.unpricedModels.isEmpty)
        XCTAssertGreaterThan(data.totalCost, 0)
    }
}
