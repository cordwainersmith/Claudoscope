import XCTest
@testable import Claudoscope

/// Tests for the managed `modelPricing` override (Claude Code 2.1.243): an
/// organization's contracted rates, reported instead of list price.
///
/// Managed scope only, and the file does not exist on a normal machine, so
/// everything here runs against synthetic settings dicts.
final class ManagedModelPricingTests: XCTestCase {

    private let anyDay = "2026-09-14"

    private func settings(_ modelPricing: [String: Any]) -> [String: Any] {
        ["modelPricing": modelPricing]
    }

    private func row(_ input: Double, _ output: Double, _ read: Double, _ write: Double) -> [String: Any] {
        ["input": input, "output": output, "cacheRead": read, "cacheWrite": write]
    }

    // MARK: - Parsing

    func testParsesMultiplierAndOverrides() {
        let m = ManagedPricingOverride.parse(managedSettings: settings([
            "multiplier": 0.85,
            "overrides": ["claude-sonnet-4-6": row(2.4, 12, 0.24, 3)],
        ]))
        XCTAssertEqual(m.multiplier, 0.85)
        XCTAssertEqual(m.overrides["claude-sonnet-4-6"],
                       ManagedRateRow(input: 2.4, output: 12, cacheRead: 0.24, cacheWrite: 3))
    }

    func testAbsentKeyIsEmpty() {
        XCTAssertTrue(ManagedPricingOverride.parse(managedSettings: [:]).isEmpty)
        XCTAssertTrue(ManagedPricingOverride.parse(managedSettings: ["other": 1]).isEmpty)
    }

    /// Claude Code drops a row it cannot parse and keeps the rest. Repricing
    /// everything because one row has a typo would be worse than ignoring it.
    func testMalformedRowIsDroppedAndSiblingsSurvive() {
        let m = ManagedPricingOverride.parse(managedSettings: settings([
            "overrides": [
                "good": row(1, 2, 3, 4),
                "missing-cacheWrite": ["input": 1, "output": 2, "cacheRead": 3],
                "not-a-dict": "nope",
                "out-of-range": row(1, 20_000, 3, 4),
                "negative": row(-1, 2, 3, 4),
            ],
        ]))
        XCTAssertEqual(Set(m.overrides.keys), ["good"])
    }

    func testMultiplierOutsideRangeIsDropped() {
        for bad in [0, -0.5, 1.5, 2] {
            let m = ManagedPricingOverride.parse(managedSettings: settings(["multiplier": bad]))
            XCTAssertNil(m.multiplier, "multiplier \(bad) must be rejected")
        }
        XCTAssertEqual(ManagedPricingOverride.parse(managedSettings: settings(["multiplier": 1])).multiplier, 1)
    }

    func testOverrideKeysAreLowercased() {
        let m = ManagedPricingOverride.parse(managedSettings: settings([
            "overrides": ["Claude-Sonnet-4-6": row(1, 2, 3, 4)],
        ]))
        XCTAssertNotNil(m.overrides["claude-sonnet-4-6"])
    }

    // MARK: - Resolution

    func testNoOverrideLeavesTheBuiltInTableUntouched() {
        let base = PricingTables.table(provider: .anthropic, region: .global)
        let resolved = PricingTables.resolvedTable(provider: .anthropic, region: .global, managed: .none)
        XCTAssertEqual(resolved.count, base.count)
        XCTAssertEqual(PricingTables.tableHash(resolved), PricingTables.tableHash(base))
    }

    /// cacheWrite is one value covering both write tiers.
    func testCacheWriteAppliesToBothTiers() {
        let m = ManagedPricingOverride.parse(managedSettings: settings([
            "overrides": ["claude-sonnet-4-6": row(2.4, 12, 0.24, 3)],
        ]))
        let t = PricingTables.resolvedTable(provider: .anthropic, region: .global, managed: m)
        let p = getModelPricing("claude-sonnet-4-6", table: t, on: anyDay)
        XCTAssertEqual(p.cacheCreation5m, 3, accuracy: 1e-9)
        XCTAssertEqual(p.cacheCreation1h, 3, accuracy: 1e-9)
        XCTAssertTrue(p.isManagedOverride)
    }

    /// A built-in model id also replaces its family row, so dated snapshots and
    /// provider-prefixed ids of the same model inherit the contracted rate.
    func testBuiltInIdReachesDatedSnapshotsAndProviderIds() {
        let m = ManagedPricingOverride.parse(managedSettings: settings([
            "overrides": ["claude-sonnet-4-6": row(2.4, 12, 0.24, 3)],
        ]))
        let t = PricingTables.resolvedTable(provider: .anthropic, region: .global, managed: m)
        for id in ["claude-sonnet-4-6", "claude-sonnet-4-6-20260115", "us.anthropic.claude-sonnet-4-6-v1"] {
            XCTAssertEqual(getModelPricing(id, table: t, on: anyDay).input, 2.4, accuracy: 1e-9,
                           "\(id) should inherit the contracted sonnet rate")
        }
    }

    /// A dated or namespaced key applies to that id alone, and an exact match
    /// beats the family row it would otherwise fall through to.
    func testExactIdKeyWinsOverTheFamilyRow() {
        let m = ManagedPricingOverride.parse(managedSettings: settings([
            "overrides": [
                "claude-sonnet-4-6": row(2.4, 12, 0.24, 3),
                "claude-sonnet-4-6-20260115": row(9, 9, 9, 9),
            ],
        ]))
        let t = PricingTables.resolvedTable(provider: .anthropic, region: .global, managed: m)
        XCTAssertEqual(getModelPricing("claude-sonnet-4-6-20260115", table: t, on: anyDay).input, 9, accuracy: 1e-9)
        XCTAssertEqual(getModelPricing("claude-sonnet-4-6", table: t, on: anyDay).input, 2.4, accuracy: 1e-9)
        // A sibling snapshot with no exact row still gets the family rate.
        XCTAssertEqual(getModelPricing("claude-sonnet-4-6-20260220", table: t, on: anyDay).input, 2.4, accuracy: 1e-9)
    }

    func testGatewayAliasAppliesToItselfOnly() {
        let m = ManagedPricingOverride.parse(managedSettings: settings([
            "overrides": ["vendor/fast-sonnet": row(1, 1, 1, 1)],
        ]))
        let t = PricingTables.resolvedTable(provider: .anthropic, region: .global, managed: m)
        XCTAssertEqual(getModelPricing("vendor/fast-sonnet", table: t, on: anyDay).input, 1, accuracy: 1e-9)
        // The real sonnet row is untouched.
        XCTAssertEqual(getModelPricing("claude-sonnet-4-6", table: t, on: anyDay).input, 3, accuracy: 1e-9)
    }

    func testBuiltInIdHeuristic() {
        XCTAssertTrue(PricingTables.looksLikeBuiltInModelId("claude-opus-5"))
        XCTAssertFalse(PricingTables.looksLikeBuiltInModelId("claude-opus-5-20260115"))
        XCTAssertFalse(PricingTables.looksLikeBuiltInModelId("vendor/alias"))
        XCTAssertFalse(PricingTables.looksLikeBuiltInModelId("gateway:alias"))
    }

    /// An unrecognized key must not install itself as the "unknown" family
    /// row. That row is the fallthrough for every model with no rate, so
    /// writing to it would silently reprice all of them and suppress the
    /// unpriced-model notice in Analytics.
    func testUnrecognizedKeyDoesNotHijackTheUnknownRow() {
        let base = PricingTables.table(provider: .anthropic, region: .global)
        let m = ManagedPricingOverride.parse(managedSettings: settings([
            "overrides": ["totally-made-up-model": row(1, 1, 1, 1)],
        ]))
        let t = PricingTables.resolvedTable(provider: .anthropic, region: .global, managed: m)
        let familyKeys = t.keys.filter { !$0.hasPrefix(managedExactKeyPrefix) }
        XCTAssertEqual(Set(familyKeys), Set(base.keys),
                       "an unrecognized key must only add its own @id: row")
        // The override still applies to that exact id.
        XCTAssertEqual(getModelPricing("totally-made-up-model", table: t, on: anyDay).input, 1, accuracy: 1e-9)
        // A different unrecognized model still bills nothing and stays visible
        // to the unpriced-model notice.
        let other = getModelPricing("some-other-unknown-model", table: t, on: anyDay)
        XCTAssertTrue(other.isUnknown)
        XCTAssertEqual(other.input, 0)
    }

    // MARK: - Multiplier

    func testMultiplierScalesEveryRowIncludingUncoveredOnes() {
        let m = ManagedPricingOverride.parse(managedSettings: settings(["multiplier": 0.5]))
        let t = PricingTables.resolvedTable(provider: .anthropic, region: .global, managed: m)
        XCTAssertEqual(getModelPricing("claude-opus-5", table: t, on: anyDay).input, 2.5, accuracy: 1e-9)
        XCTAssertEqual(getModelPricing("claude-haiku-4-5", table: t, on: anyDay).output, 2.5, accuracy: 1e-9)
    }

    /// The fee is added separately from token cost, so a multiplier applied at
    /// cost-computation time would miss it. Applying it to the table catches it.
    func testMultiplierScalesTheWebSearchFee() {
        let m = ManagedPricingOverride.parse(managedSettings: settings(["multiplier": 0.5]))
        let t = PricingTables.resolvedTable(provider: .anthropic, region: .global, managed: m)
        XCTAssertEqual(webSearchFee(table: t), 0.005, accuracy: 1e-12)
    }

    func testMultiplierStacksOnTopOfAnOverrideRow() {
        let m = ManagedPricingOverride.parse(managedSettings: settings([
            "multiplier": 0.5,
            "overrides": ["claude-sonnet-4-6": row(2.4, 12, 0.24, 3)],
        ]))
        let t = PricingTables.resolvedTable(provider: .anthropic, region: .global, managed: m)
        XCTAssertEqual(getModelPricing("claude-sonnet-4-6", table: t, on: anyDay).input, 1.2, accuracy: 1e-9)
    }

    /// An override row keeps billing web searches rather than dropping to zero.
    func testOverrideRowCarriesTheWebSearchFee() {
        let m = ManagedPricingOverride.parse(managedSettings: settings([
            "overrides": ["claude-sonnet-4-6": row(2.4, 12, 0.24, 3)],
        ]))
        let t = PricingTables.resolvedTable(provider: .anthropic, region: .global, managed: m)
        XCTAssertEqual(getModelPricing("claude-sonnet-4-6", table: t, on: anyDay).webSearchRequestFee,
                       0.01, accuracy: 1e-12)
    }

    // MARK: - Fast mode

    /// A contracted rate is used exactly as written, with no fast-mode
    /// surcharge on top. An uncovered model keeps the 2x.
    func testOverriddenModelIgnoresFastModeButOthersDoNot() {
        let m = ManagedPricingOverride.parse(managedSettings: settings([
            "overrides": ["claude-sonnet-4-6": row(10, 10, 0, 0)],
        ]))
        let t = PricingTables.resolvedTable(provider: .anthropic, region: .global, managed: m)

        let overridden = estimateCostFromTokens(
            model: "claude-sonnet-4-6", inputTokens: 1_000_000, outputTokens: 0,
            cacheReadTokens: 0, cacheCreation5mTokens: 0, cacheCreation1hTokens: 0,
            table: t, on: anyDay, speedMultiplier: fastModeRateMultiplier
        )
        XCTAssertEqual(overridden, 10, accuracy: 1e-9, "contracted rate must not take the 2x")

        let uncovered = estimateCostFromTokens(
            model: "claude-opus-5", inputTokens: 1_000_000, outputTokens: 0,
            cacheReadTokens: 0, cacheCreation5mTokens: 0, cacheCreation1hTokens: 0,
            table: t, on: anyDay, speedMultiplier: fastModeRateMultiplier
        )
        XCTAssertEqual(uncovered, 10, accuracy: 1e-9, "opus $5 x 2 fast mode")
    }

    // MARK: - Cache invalidation

    private func key(_ managed: ManagedPricingOverride?) -> String {
        PricingTables.cacheKey(provider: .anthropic, region: .global, managed: managed)
    }

    /// Both directions must invalidate. Hashing the resolved table gets that
    /// for free: removing an override restores the original hash, which is
    /// equally a mismatch against the stored key.
    func testAddingAndRemovingAnOverrideBothChangeTheKey() {
        let none = key(.none)
        let withOverride = key(ManagedPricingOverride.parse(managedSettings: settings([
            "overrides": ["claude-sonnet-4-6": row(2.4, 12, 0.24, 3)],
        ])))
        XCTAssertNotEqual(none, withOverride)
        XCTAssertEqual(key(.none), none, "removing the override returns to the original key")
    }

    /// A pure-multiplier override has no overrides rows, so it only invalidates
    /// because the multiplier is baked into the rates at table-build time.
    func testMultiplierAloneChangesTheKey() {
        XCTAssertNotEqual(
            key(.none),
            key(ManagedPricingOverride.parse(managedSettings: settings(["multiplier": 0.9])))
        )
    }

    func testDifferentMultipliersProduceDifferentKeys() {
        let a = key(ManagedPricingOverride.parse(managedSettings: settings(["multiplier": 0.9])))
        let b = key(ManagedPricingOverride.parse(managedSettings: settings(["multiplier": 0.8])))
        XCTAssertNotEqual(a, b)
    }

    /// On an unmanaged machine the resolved table IS the built-in table, so the
    /// key is whatever hashing that table gives.
    ///
    /// Note this does not mean the key is unchanged from before the feature:
    /// `isManagedOverride` was added to tableHash's canonical string, so every
    /// user takes exactly one cache wipe when this ships. That is deliberate
    /// and rides along with the parserVersion 7 -> 8 bump in the same release.
    func testUnmanagedKeyMatchesTheUnresolvedTable() {
        XCTAssertEqual(
            key(.none),
            "anthropic|global|" + PricingTables.tableHash(PricingTables.anthropic)
        )
    }
}
