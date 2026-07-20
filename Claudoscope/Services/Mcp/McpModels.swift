import Foundation

struct McpServerConfig: Codable, Sendable, Equatable {
    var enabled: Bool

    static let `default` = McpServerConfig(enabled: false)

    init(enabled: Bool) {
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    }
}

enum McpServerStatus: Sendable, Equatable {
    case stopped
    case starting
    case running(clientCount: Int)
    case error(String)
}

enum McpRegistrationState: Sendable, Equatable {
    case unknown
    case registered
    case notRegistered
    case cliNotFound(manualCommand: String)
    case failed(String)
}

/// Value-type snapshot of SessionStore state, taken on the MainActor per
/// tool call so handlers can work off-main with dashboard-identical data.
struct McpStoreSnapshot: Sendable {
    let projects: [Project]
    let sessionsByProject: [String: [SessionSummary]]
    let pricingTable: [String: ModelPricing]
    let canonOptedInProjectIds: Set<String>
    let bundledCanonProtocolVersion: Int

    static let empty = McpStoreSnapshot(
        projects: [],
        sessionsByProject: [:],
        pricingTable: [:],
        canonOptedInProjectIds: [],
        bundledCanonProtocolVersion: 0
    )
}

/// Everything a tool handler needs. The config/linter/plans services are
/// stateless disk readers owned by McpServerService, not the store's own.
struct McpToolContext: Sendable {
    let snapshot: @Sendable () async -> McpStoreSnapshot
    let configService: ConfigService
    let linterService: ConfigLinterService
    let plansService: PlansService
    let claudeDir: URL
}
