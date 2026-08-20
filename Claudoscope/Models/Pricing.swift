import CryptoKit
import Foundation

enum PricingProvider: String, CaseIterable, Sendable {
    case anthropic
    case vertex
}

enum VertexRegion: String, CaseIterable, Sendable {
    case global
    case usEast5 = "us-east5"
    case europeWest1 = "europe-west1"
    case asiaSoutheast1 = "asia-southeast1"
}

struct ModelPricing: Sendable {
    let input: Double    // per MTok
    let output: Double
    let cacheRead: Double
    let cacheCreation5m: Double
    let cacheCreation1h: Double
    // USD per web_search server-tool request; 0 = not priced. Default 0 so a
    // family added to a table later is never silently billed a fee it may not incur.
    var webSearchRequestFee: Double = 0
    var isUnknown: Bool = false

    static let unknown = ModelPricing(
        input: 0, output: 0, cacheRead: 0, cacheCreation5m: 0, cacheCreation1h: 0, isUnknown: true
    )
}

struct PricingTables {
    static let anthropic: [String: ModelPricing] = [
        "fable":  ModelPricing(input: 10,    output: 50,    cacheRead: 1.00,   cacheCreation5m: 12.50,  cacheCreation1h: 20,   webSearchRequestFee: 0.01),
        "mythos": ModelPricing(input: 10,    output: 50,    cacheRead: 1.00,   cacheCreation5m: 12.50,  cacheCreation1h: 20,   webSearchRequestFee: 0.01),
        "opus":   ModelPricing(input: 5,     output: 25,    cacheRead: 0.50,   cacheCreation5m: 6.25,   cacheCreation1h: 10,   webSearchRequestFee: 0.01),
        "opus4":  ModelPricing(input: 15,    output: 75,    cacheRead: 1.50,   cacheCreation5m: 18.75,  cacheCreation1h: 30,   webSearchRequestFee: 0.01),
        "sonnet": ModelPricing(input: 3,     output: 15,    cacheRead: 0.30,   cacheCreation5m: 3.75,   cacheCreation1h: 6,    webSearchRequestFee: 0.01),
        "sonnet5": ModelPricing(input: 2,    output: 10,    cacheRead: 0.20,   cacheCreation5m: 2.50,   cacheCreation1h: 4,    webSearchRequestFee: 0.01),
        "haiku":  ModelPricing(input: 1,     output: 5,     cacheRead: 0.10,   cacheCreation5m: 1.25,   cacheCreation1h: 2,    webSearchRequestFee: 0.01),
        "haiku35": ModelPricing(input: 0.80, output: 4,     cacheRead: 0.08,   cacheCreation5m: 1.00,   cacheCreation1h: 1.60, webSearchRequestFee: 0.01),
        "haiku3": ModelPricing(input: 0.25,  output: 1.25,  cacheRead: 0.03,   cacheCreation5m: 0.30,   cacheCreation1h: 0.50, webSearchRequestFee: 0.01),
    ]

    static let vertexGlobal: [String: ModelPricing] = [
        // Fable and Mythos on Vertex are provisional: they assume Anthropic-mirrored
        // rates and are not yet bill-validated.
        "fable":  ModelPricing(input: 10,    output: 50,    cacheRead: 1.00,   cacheCreation5m: 12.50,  cacheCreation1h: 20,   webSearchRequestFee: 0.01),
        "mythos": ModelPricing(input: 10,    output: 50,    cacheRead: 1.00,   cacheCreation5m: 12.50,  cacheCreation1h: 20,   webSearchRequestFee: 0.01),
        "opus":   ModelPricing(input: 5,     output: 25,    cacheRead: 0.50,   cacheCreation5m: 6.25,   cacheCreation1h: 10,   webSearchRequestFee: 0.01),
        "opus4":  ModelPricing(input: 15,    output: 75,    cacheRead: 1.50,   cacheCreation5m: 18.75,  cacheCreation1h: 30,   webSearchRequestFee: 0.01),
        "sonnet": ModelPricing(input: 3,     output: 15,    cacheRead: 0.30,   cacheCreation5m: 3.75,   cacheCreation1h: 6,    webSearchRequestFee: 0.01),
        "sonnet5": ModelPricing(input: 2,    output: 10,    cacheRead: 0.20,   cacheCreation5m: 2.50,   cacheCreation1h: 4,    webSearchRequestFee: 0.01),
        "haiku":  ModelPricing(input: 1,     output: 5,     cacheRead: 0.10,   cacheCreation5m: 1.25,   cacheCreation1h: 2,    webSearchRequestFee: 0.01),
        "haiku35": ModelPricing(input: 0.80, output: 4,     cacheRead: 0.08,   cacheCreation5m: 1.00,   cacheCreation1h: 1.60, webSearchRequestFee: 0.01),
        "haiku3": ModelPricing(input: 0.25,  output: 1.25,  cacheRead: 0.03,   cacheCreation5m: 0.30,   cacheCreation1h: 0.50, webSearchRequestFee: 0.01),
    ]

    static let vertexRegional: [String: ModelPricing] = [
        // Fable and Mythos on Vertex are provisional: they assume Anthropic rate x1.1
        // regional and are not yet bill-validated.
        "fable":  ModelPricing(input: 11,    output: 55,     cacheRead: 1.10,   cacheCreation5m: 13.75,   cacheCreation1h: 22,   webSearchRequestFee: 0.011),
        "mythos": ModelPricing(input: 11,    output: 55,     cacheRead: 1.10,   cacheCreation5m: 13.75,   cacheCreation1h: 22,   webSearchRequestFee: 0.011),
        "opus":   ModelPricing(input: 5.50,  output: 27.50,  cacheRead: 0.55,   cacheCreation5m: 6.875,   cacheCreation1h: 11,   webSearchRequestFee: 0.011),
        "opus4":  ModelPricing(input: 16.50, output: 82.50,  cacheRead: 1.65,   cacheCreation5m: 20.625,  cacheCreation1h: 33,   webSearchRequestFee: 0.011),
        "sonnet": ModelPricing(input: 3.30,  output: 16.50,  cacheRead: 0.33,   cacheCreation5m: 4.125,   cacheCreation1h: 6.60, webSearchRequestFee: 0.011),
        "sonnet5": ModelPricing(input: 2.20, output: 11,     cacheRead: 0.22,   cacheCreation5m: 2.75,    cacheCreation1h: 4.40, webSearchRequestFee: 0.011),
        "haiku":  ModelPricing(input: 1.10,  output: 5.50,   cacheRead: 0.11,   cacheCreation5m: 1.375,   cacheCreation1h: 2.20, webSearchRequestFee: 0.011),
        "haiku35": ModelPricing(input: 0.88, output: 4.40,   cacheRead: 0.088,  cacheCreation5m: 1.10,    cacheCreation1h: 1.76, webSearchRequestFee: 0.011),
        "haiku3": ModelPricing(input: 0.275, output: 1.375,  cacheRead: 0.033,  cacheCreation5m: 0.33,    cacheCreation1h: 0.55, webSearchRequestFee: 0.011),
    ]

    static func table(provider: PricingProvider, region: VertexRegion) -> [String: ModelPricing] {
        switch provider {
        case .anthropic: return anthropic
        case .vertex:
            return region == .global ? vertexGlobal : vertexRegional
        }
    }

    /// Invalidation key for the persistent summary cache. Cost is baked into
    /// cached summaries, so the key must change whenever anything that feeds
    /// `estimateCostFromTokens` changes: provider/region selection, any rate
    /// in the selected table, or the fast-mode multiplier. Hashing the rates
    /// makes hardcoded table edits self-invalidating with no manual bump.
    static func cacheKey(provider: PricingProvider, region: VertexRegion) -> String {
        let hash = tableHash(table(provider: provider, region: region))
        return "\(provider.rawValue)|\(region.rawValue)|\(hash)"
    }

    /// SHA256 over a canonical serialization of the table plus the fast-mode
    /// multiplier and the dated-rate windows. Internal (not private) so tests can
    /// hash synthetic tables; `fastMultiplier` and `rateWindows` are parameterized
    /// for the same reason. The windows are included so that opening or moving one —
    /// which changes cost without touching any rate — still invalidates the cache.
    static func tableHash(
        _ table: [String: ModelPricing],
        fastMultiplier: Double = fastModeRateMultiplier,
        rateWindows: String = datedRateWindowFingerprint
    ) -> String {
        var canonical = ""
        for key in table.keys.sorted() {
            let p = table[key]!
            canonical += "\(key):\(p.input),\(p.output),\(p.cacheRead),\(p.cacheCreation5m),\(p.cacheCreation1h),\(p.webSearchRequestFee);"
        }
        canonical += "fast:\(fastMultiplier)|windows:\(rateWindows)"
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Model generations that billed at the pre-4.5 rate. Closed lists rather than a
/// version comparison: an id nobody anticipated prices at the current rate instead
/// of inheriting the 3x legacy one, which is how claude-opus-5 was mispriced.
private let legacyOpusMarkers = ["claude-3-opus", "opus-4-0", "opus-4-1"]
private let legacyHaikuMarkers = ["claude-3-haiku", "claude-3-5-haiku"]

/// Ids that bill at their own rate rather than their family's standard row, as
/// (id marker, pricing-table key) pairs. Sonnet 5 is $2/$10 against Sonnet 4.5/4.6's
/// $3/$15; Haiku 3.5 is $0.80/$4 against Haiku 3's $0.25/$1.25. Both are permanent
/// rate differences, not dated windows: Anthropic cancelled the 2026-09-01 increase
/// that would have moved Sonnet 5 onto the standard row.
private let rateSplitMarkers: [(marker: String, key: String)] = [
    ("sonnet-5", "sonnet5"),
    ("claude-3-5-haiku", "haiku35"),
]

/// Canonical fingerprint of the dated rate windows in force, hashed into the cache
/// key. No window is open today. It stays in the key because opening or moving one
/// changes cost without touching a single rate, and cached summaries bake in cost.
let datedRateWindowFingerprint = ""

private func matchesAny(_ model: String, _ markers: [String]) -> Bool {
    markers.contains { model.contains($0) }
}

/// The family is a display label, a persisted per-day map key, and an analytics
/// aggregation key as well as a pricing lookup. Do NOT split it to express a rate
/// difference: that would surface in the UI and permanently fork one model's rows
/// in every breakdown. Rate-only distinctions belong in `pricingKey` below.
func getModelFamily(_ model: String?) -> String {
    guard let model = model?.lowercased() else { return "unknown" }
    if model.contains("fable") { return "fable" }
    if model.contains("mythos") { return "mythos" }
    if model.contains("opus") {
        return matchesAny(model, legacyOpusMarkers) ? "opus4" : "opus"
    }
    if model.contains("haiku") {
        return matchesAny(model, legacyHaikuMarkers) ? "haiku3" : "haiku"
    }
    if model.contains("sonnet") { return "sonnet" }
    return "unknown"
}

/// Table row for a model on a given LOCAL day ("YYYY-MM-DD"). Usually the family,
/// but an id with its own rate resolves to its own row. The only place "sonnet5"
/// and "haiku35" are produced — they never escape this file.
///
/// `day` is unused while no dated window is open. It stays in the signature (and
/// threaded through the callers) because the per-message date is the input a dated
/// rate needs, and retrofitting it costs far more than carrying it.
private func pricingKey(_ model: String?, on day: String) -> String {
    guard let model = model?.lowercased() else { return getModelFamily(nil) }
    for split in rateSplitMarkers where model.contains(split.marker) {
        return split.key
    }
    return getModelFamily(model)
}

/// `day` is the LOCAL calendar day of the message being priced, so historical
/// cost stays fixed as dated rate windows open and close.
func getModelPricing(_ model: String?, table: [String: ModelPricing], on day: String) -> ModelPricing {
    table[pricingKey(model, on: day)] ?? .unknown
}

/// Fast-mode billing multiplier. Confirmed against the published pricing page:
/// Opus 5 / Opus 4.8 fast mode is $10/$50 against a $5/$25 standard rate, exactly
/// 2x, and prompt-caching multipliers stack *on top of* fast-mode pricing — which
/// is why this multiplies the whole cost, cache tokens included. Applied only when
/// a record's `speed` field is non-standard (see SessionParser).
let fastModeRateMultiplier: Double = 2.0

func estimateCostFromTokens(
    model: String?,
    inputTokens: Int,
    outputTokens: Int,
    cacheReadTokens: Int,
    cacheCreation5mTokens: Int,
    cacheCreation1hTokens: Int,
    table: [String: ModelPricing],
    on day: String,
    speedMultiplier: Double = 1.0
) -> Double {
    let p = getModelPricing(model, table: table, on: day)
    let base = (Double(inputTokens) / 1e6) * p.input
         + (Double(outputTokens) / 1e6) * p.output
         + (Double(cacheReadTokens) / 1e6) * p.cacheRead
         + (Double(cacheCreation5mTokens) / 1e6) * p.cacheCreation5m
         + (Double(cacheCreation1hTokens) / 1e6) * p.cacheCreation1h
    return base * speedMultiplier
}

/// Flat web-search request fee for a table. Uniform across families by
/// construction (all rows carry the same fee), so this returns the max priced
/// value; 0 if no family in the table is priced. The web-search count comes
/// from ToolUseResultRaw.searchCount, not from token usage, so the fee is added
/// separately from estimateCostFromTokens.
func webSearchFee(table: [String: ModelPricing]) -> Double {
    table.values.map(\.webSearchRequestFee).max() ?? 0
}
