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
        "opus":   ModelPricing(input: 5,     output: 25,    cacheRead: 0.50,   cacheCreation5m: 6.25,   cacheCreation1h: 10,   webSearchRequestFee: 0.01),
        "opus4":  ModelPricing(input: 15,    output: 75,    cacheRead: 1.50,   cacheCreation5m: 18.75,  cacheCreation1h: 30,   webSearchRequestFee: 0.01),
        "sonnet": ModelPricing(input: 3,     output: 15,    cacheRead: 0.30,   cacheCreation5m: 3.75,   cacheCreation1h: 6,    webSearchRequestFee: 0.01),
        "haiku":  ModelPricing(input: 1,     output: 5,     cacheRead: 0.10,   cacheCreation5m: 1.25,   cacheCreation1h: 2,    webSearchRequestFee: 0.01),
        "haiku3": ModelPricing(input: 0.25,  output: 1.25,  cacheRead: 0.03,   cacheCreation5m: 0.30,   cacheCreation1h: 0.50, webSearchRequestFee: 0.01),
    ]

    static let vertexGlobal: [String: ModelPricing] = [
        // Fable on Vertex is provisional: assumes Anthropic-mirrored rates, not yet bill-validated.
        "fable":  ModelPricing(input: 10,    output: 50,    cacheRead: 1.00,   cacheCreation5m: 12.50,  cacheCreation1h: 20,   webSearchRequestFee: 0.01),
        "opus":   ModelPricing(input: 5,     output: 25,    cacheRead: 0.50,   cacheCreation5m: 6.25,   cacheCreation1h: 10,   webSearchRequestFee: 0.01),
        "opus4":  ModelPricing(input: 15,    output: 75,    cacheRead: 1.50,   cacheCreation5m: 18.75,  cacheCreation1h: 30,   webSearchRequestFee: 0.01),
        "sonnet": ModelPricing(input: 3,     output: 15,    cacheRead: 0.30,   cacheCreation5m: 3.75,   cacheCreation1h: 6,    webSearchRequestFee: 0.01),
        "haiku":  ModelPricing(input: 1,     output: 5,     cacheRead: 0.10,   cacheCreation5m: 1.25,   cacheCreation1h: 2,    webSearchRequestFee: 0.01),
        "haiku3": ModelPricing(input: 0.25,  output: 1.25,  cacheRead: 0.03,   cacheCreation5m: 0.30,   cacheCreation1h: 0.50, webSearchRequestFee: 0.01),
    ]

    static let vertexRegional: [String: ModelPricing] = [
        // Fable on Vertex is provisional: assumes Anthropic rate x1.1 regional, not yet bill-validated.
        "fable":  ModelPricing(input: 11,    output: 55,     cacheRead: 1.10,   cacheCreation5m: 13.75,   cacheCreation1h: 22,   webSearchRequestFee: 0.011),
        "opus":   ModelPricing(input: 5.50,  output: 27.50,  cacheRead: 0.55,   cacheCreation5m: 6.875,   cacheCreation1h: 11,   webSearchRequestFee: 0.011),
        "opus4":  ModelPricing(input: 16.50, output: 82.50,  cacheRead: 1.65,   cacheCreation5m: 20.625,  cacheCreation1h: 33,   webSearchRequestFee: 0.011),
        "sonnet": ModelPricing(input: 3.30,  output: 16.50,  cacheRead: 0.33,   cacheCreation5m: 4.125,   cacheCreation1h: 6.60, webSearchRequestFee: 0.011),
        "haiku":  ModelPricing(input: 1.10,  output: 5.50,   cacheRead: 0.11,   cacheCreation5m: 1.375,   cacheCreation1h: 2.20, webSearchRequestFee: 0.011),
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
    /// multiplier. Internal (not private) so tests can hash synthetic tables;
    /// `fastMultiplier` is parameterized for the same reason.
    static func tableHash(_ table: [String: ModelPricing], fastMultiplier: Double = fastModeRateMultiplier) -> String {
        var canonical = ""
        for key in table.keys.sorted() {
            let p = table[key]!
            canonical += "\(key):\(p.input),\(p.output),\(p.cacheRead),\(p.cacheCreation5m),\(p.cacheCreation1h),\(p.webSearchRequestFee);"
        }
        canonical += "fast:\(fastMultiplier)"
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Parse version from a model ID like "claude-opus-4-5-20250120" or "claude-opus-5".
/// Returns true if version is 4.5+ (major >= 5, or major == 4 and minor >= 5).
private func isVersion45OrHigher(_ model: String) -> Bool {
    // Minor is optional: "opus-5" is a one-part version, "opus-4-8" a two-part one.
    // Version components are capped at two digits and followed by a non-digit so a
    // legacy datestamp ("claude-3-opus-20240229") is not read as major version 20240229.
    guard let range = model.range(
        of: #"(?:opus|haiku|sonnet)-(\d{1,2})(?:-(\d{1,2}))?(?![0-9])"#,
        options: .regularExpression
    ) else {
        return false
    }
    let parts = model[range].split(separator: "-").compactMap { Int($0) }
    guard let major = parts.first else { return false }
    let minor = parts.count > 1 ? parts[1] : 0
    return major >= 5 || (major == 4 && minor >= 5)
}

func getModelFamily(_ model: String?) -> String {
    guard let model = model?.lowercased() else { return "unknown" }
    if model.contains("fable") { return "fable" }
    if model.contains("opus") {
        return isVersion45OrHigher(model) ? "opus" : "opus4"
    }
    if model.contains("haiku") {
        return isVersion45OrHigher(model) ? "haiku" : "haiku3"
    }
    if model.contains("sonnet") { return "sonnet" }
    return "unknown"
}

func getModelPricing(_ model: String?, table: [String: ModelPricing]) -> ModelPricing {
    let family = getModelFamily(model)
    return table[family] ?? .unknown
}

/// Fast-mode billing multiplier, sourced from the 2.1.154 changelog
/// ("2x the standard rate for 2.5x the speed"). Provisional: not yet
/// validated against a real bill. Applied only when a record's `speed`
/// field is non-standard (see SessionParser).
let fastModeRateMultiplier: Double = 2.0

func estimateCostFromTokens(
    model: String?,
    inputTokens: Int,
    outputTokens: Int,
    cacheReadTokens: Int,
    cacheCreation5mTokens: Int,
    cacheCreation1hTokens: Int,
    table: [String: ModelPricing],
    speedMultiplier: Double = 1.0
) -> Double {
    let p = getModelPricing(model, table: table)
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
