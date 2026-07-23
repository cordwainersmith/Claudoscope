import XCTest
@testable import Claudoscope

/// The pricing cache key must change whenever anything that feeds
/// estimateCostFromTokens changes, because cost is baked into cached
/// summaries. A rate edit that does NOT change the key means users keep
/// stale costs after an app update.
final class PricingCacheKeyTests: XCTestCase {

    func testKeyDeterministicAcrossCalls() {
        XCTAssertEqual(
            PricingTables.cacheKey(provider: .anthropic, region: .global),
            PricingTables.cacheKey(provider: .anthropic, region: .global)
        )
    }

    func testKeyDiffersAcrossProvidersAndRegions() {
        let anthropic = PricingTables.cacheKey(provider: .anthropic, region: .global)
        let vertexGlobal = PricingTables.cacheKey(provider: .vertex, region: .global)
        let vertexRegional = PricingTables.cacheKey(provider: .vertex, region: .usEast5)
        XCTAssertNotEqual(anthropic, vertexGlobal)
        XCTAssertNotEqual(vertexGlobal, vertexRegional)
    }

    func testKeyChangesWhenAnyRateFieldChanges() {
        let base = ModelPricing(input: 5, output: 25, cacheRead: 0.5, cacheCreation5m: 6.25, cacheCreation1h: 10)
        let baseHash = PricingTables.tableHash(["m": base])

        let variants: [(String, ModelPricing)] = [
            ("input", ModelPricing(input: 5.5, output: 25, cacheRead: 0.5, cacheCreation5m: 6.25, cacheCreation1h: 10)),
            ("output", ModelPricing(input: 5, output: 26, cacheRead: 0.5, cacheCreation5m: 6.25, cacheCreation1h: 10)),
            ("cacheRead", ModelPricing(input: 5, output: 25, cacheRead: 0.55, cacheCreation5m: 6.25, cacheCreation1h: 10)),
            ("cacheCreation5m", ModelPricing(input: 5, output: 25, cacheRead: 0.5, cacheCreation5m: 6.875, cacheCreation1h: 10)),
            ("cacheCreation1h", ModelPricing(input: 5, output: 25, cacheRead: 0.5, cacheCreation5m: 6.25, cacheCreation1h: 11)),
            ("webSearchRequestFee", ModelPricing(input: 5, output: 25, cacheRead: 0.5, cacheCreation5m: 6.25, cacheCreation1h: 10, webSearchRequestFee: 0.01)),
        ]
        for (field, variant) in variants {
            XCTAssertNotEqual(
                baseHash,
                PricingTables.tableHash(["m": variant]),
                "changing \(field) must change the hash"
            )
        }
    }

    func testHashIncludesModelAdditionsAndFastMultiplier() {
        let m = ModelPricing(input: 1, output: 2, cacheRead: 0.1, cacheCreation5m: 0.5, cacheCreation1h: 1)
        let one = PricingTables.tableHash(["a": m])
        let two = PricingTables.tableHash(["a": m, "b": m])
        XCTAssertNotEqual(one, two, "adding a model must change the hash")

        XCTAssertNotEqual(
            PricingTables.tableHash(["a": m], fastMultiplier: 2.0),
            PricingTables.tableHash(["a": m], fastMultiplier: 3.0),
            "fast-mode multiplier must be part of the hash"
        )
    }
}
