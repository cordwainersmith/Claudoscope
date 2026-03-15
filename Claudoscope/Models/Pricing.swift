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
    let cacheCreation: Double
}

struct PricingTables {
    static let anthropic: [String: ModelPricing] = [
        "opus":   ModelPricing(input: 5,     output: 25,    cacheRead: 0.50,   cacheCreation: 6.25),
        "opus4":  ModelPricing(input: 15,    output: 75,    cacheRead: 1.50,   cacheCreation: 18.75),
        "sonnet": ModelPricing(input: 3,     output: 15,    cacheRead: 0.30,   cacheCreation: 3.75),
        "haiku":  ModelPricing(input: 1,     output: 5,     cacheRead: 0.10,   cacheCreation: 1.25),
        "haiku3": ModelPricing(input: 0.25,  output: 1.25,  cacheRead: 0.03,   cacheCreation: 0.30),
    ]

    static let vertexGlobal: [String: ModelPricing] = [
        "opus":   ModelPricing(input: 5,     output: 25,    cacheRead: 0.50,   cacheCreation: 6.25),
        "opus4":  ModelPricing(input: 15,    output: 75,    cacheRead: 1.50,   cacheCreation: 18.75),
        "sonnet": ModelPricing(input: 3,     output: 15,    cacheRead: 0.30,   cacheCreation: 3.75),
        "haiku":  ModelPricing(input: 1,     output: 5,     cacheRead: 0.10,   cacheCreation: 1.25),
        "haiku3": ModelPricing(input: 0.25,  output: 1.25,  cacheRead: 0.03,   cacheCreation: 0.30),
    ]

    static let vertexRegional: [String: ModelPricing] = [
        "opus":   ModelPricing(input: 5.50,  output: 27.50,  cacheRead: 0.55,   cacheCreation: 6.875),
        "opus4":  ModelPricing(input: 16.50, output: 82.50,  cacheRead: 1.65,   cacheCreation: 20.625),
        "sonnet": ModelPricing(input: 3.30,  output: 16.50,  cacheRead: 0.33,   cacheCreation: 4.125),
        "haiku":  ModelPricing(input: 1.10,  output: 5.50,   cacheRead: 0.11,   cacheCreation: 1.375),
        "haiku3": ModelPricing(input: 0.275, output: 1.375,  cacheRead: 0.033,  cacheCreation: 0.33),
    ]

    static func table(provider: PricingProvider, region: VertexRegion) -> [String: ModelPricing] {
        switch provider {
        case .anthropic: return anthropic
        case .vertex:
            return region == .global ? vertexGlobal : vertexRegional
        }
    }
}

/// Parse version from a model ID like "claude-opus-4-5-20250120".
/// Returns true if version is 4.5+ (major >= 5, or major == 4 and minor >= 5).
private func isVersion45OrHigher(_ model: String) -> Bool {
    // Match digits after family name, e.g. "opus-4-5" or "haiku-3-5"
    guard let range = model.range(of: #"(?:opus|haiku|sonnet)-(\d+)-(\d+)"#, options: .regularExpression) else {
        return false
    }
    let matched = String(model[range])
    let parts = matched.split(separator: "-")
    guard parts.count >= 3,
          let major = Int(parts[parts.count - 2]),
          let minor = Int(parts[parts.count - 1]) else {
        return false
    }
    return major >= 5 || (major == 4 && minor >= 5)
}

func getModelFamily(_ model: String?) -> String {
    guard let model = model?.lowercased() else { return "sonnet" }
    if model.contains("opus") {
        return isVersion45OrHigher(model) ? "opus" : "opus4"
    }
    if model.contains("haiku") {
        return isVersion45OrHigher(model) ? "haiku" : "haiku3"
    }
    if model.contains("sonnet") { return "sonnet" }
    return "sonnet"
}

func getModelPricing(_ model: String?, table: [String: ModelPricing]) -> ModelPricing {
    let family = getModelFamily(model)
    return table[family] ?? table["sonnet"] ?? ModelPricing(input: 3, output: 15, cacheRead: 0.30, cacheCreation: 3.75)
}

func estimateCostFromTokens(
    model: String?,
    inputTokens: Int,
    outputTokens: Int,
    cacheReadTokens: Int,
    cacheCreationTokens: Int,
    table: [String: ModelPricing]
) -> Double {
    let p = getModelPricing(model, table: table)
    return (Double(inputTokens) / 1e6) * p.input
         + (Double(outputTokens) / 1e6) * p.output
         + (Double(cacheReadTokens) / 1e6) * p.cacheRead
         + (Double(cacheCreationTokens) / 1e6) * p.cacheCreation
}
