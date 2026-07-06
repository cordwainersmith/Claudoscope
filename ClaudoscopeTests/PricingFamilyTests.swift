import XCTest
@testable import Claudoscope

/// Tests for pricing-family support: family detection, the three pricing
/// tables, the cost-estimation path, and end-to-end session parses. Covers
/// Claude Fable 5 (`claude-fable-5`) and Claude Sonnet 5 (`claude-sonnet-5`).
final class PricingFamilyTests: XCTestCase {

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
        let p = getModelPricing("claude-fable-5", table: PricingTables.anthropic)
        XCTAssertFalse(p.isUnknown)
        XCTAssertEqual(p.input, 10.0, accuracy: 1e-9)
        XCTAssertEqual(p.output, 50.0, accuracy: 1e-9)
        XCTAssertEqual(p.cacheRead, 1.0, accuracy: 1e-9)
        XCTAssertEqual(p.cacheCreation5m, 12.5, accuracy: 1e-9)
        XCTAssertEqual(p.cacheCreation1h, 20.0, accuracy: 1e-9)
    }

    func testFableVertexRegionalPricing() {
        // Guards the 1.1x regional row against a transcription error.
        let p = getModelPricing("claude-fable-5", table: PricingTables.vertexRegional)
        XCTAssertEqual(p.input, 11.0, accuracy: 1e-9)
        XCTAssertEqual(p.output, 55.0, accuracy: 1e-9)
    }

    func testOpusPricingUnchanged() {
        let p = getModelPricing("claude-opus-4-8", table: PricingTables.anthropic)
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
            table: PricingTables.anthropic
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

    // MARK: - Sonnet 5

    // Sonnet 5 (`claude-sonnet-5`) needs no dedicated table row: its rate has
    // been flat at $3/$15 across 3.5 -> 4 -> 4.5 -> 4.6 -> 5, so the existing
    // `sonnet` family already prices it (unlike opus/haiku, which split only
    // because their rates changed). These guard that the family-based design
    // keeps resolving Sonnet 5 correctly.

    func testSonnet5ResolvesToSonnetFamily() {
        XCTAssertEqual(getModelFamily("claude-sonnet-5"), "sonnet")
    }

    func testSonnet5AnthropicPricing() {
        let p = getModelPricing("claude-sonnet-5", table: PricingTables.anthropic)
        XCTAssertFalse(p.isUnknown)
        XCTAssertEqual(p.input, 3.0, accuracy: 1e-9)
        XCTAssertEqual(p.output, 15.0, accuracy: 1e-9)
        XCTAssertEqual(p.cacheRead, 0.30, accuracy: 1e-9)
        XCTAssertEqual(p.cacheCreation5m, 3.75, accuracy: 1e-9)
        XCTAssertEqual(p.cacheCreation1h, 6.0, accuracy: 1e-9)
    }

    func testSonnet5VertexRegionalPricing() {
        // Guards the 1.1x regional row for the sonnet family.
        let p = getModelPricing("claude-sonnet-5", table: PricingTables.vertexRegional)
        XCTAssertEqual(p.input, 3.30, accuracy: 1e-9)
        XCTAssertEqual(p.output, 16.50, accuracy: 1e-9)
    }

    /// End-to-end: a real `claude-sonnet-5` assistant record must price at the
    /// sonnet rate via the family -> breakdown -> cost chain, not the $0 an
    /// "unknown" family would yield.
    func testSonnet5SessionParsesAtSonnetRate() async throws {
        let parser = SessionParser()
        let rec = "{\"type\":\"assistant\",\"uuid\":\"u1\",\"sessionId\":\"sess-1\",\"timestamp\":\"2026-07-06T10:00:00.000Z\",\"message\":{\"role\":\"assistant\",\"id\":\"m1\",\"stop_reason\":\"end_turn\",\"model\":\"claude-sonnet-5\",\"usage\":{\"input_tokens\":1000,\"output_tokens\":2000,\"service_tier\":\"standard\"}}}"
        let url = try writeTempFile([rec])
        defer { try? FileManager.default.removeItem(at: url) }

        let s = try await parser.parseMetadata(url: url, sessionId: "sess-1", pricingTable: PricingTables.anthropic)
        XCTAssertGreaterThan(s.estimatedCost, 0)
        // 1000 input * $3/MTok + 2000 output * $15/MTok = 0.003 + 0.030 = 0.033
        XCTAssertEqual(s.estimatedCost, 0.033, accuracy: 1e-9)
    }
}
