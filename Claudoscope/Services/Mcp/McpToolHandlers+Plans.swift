import Foundation
import MCP

extension McpToolHandlers {
    struct PlanEntry: Encodable {
        let filename: String
        let title: String
        let projectHint: String?
        let createdAt: String?
        let sizeBytes: Int
        let file: String
    }

    struct PlanListResponse: Encodable {
        let plans: [PlanEntry]
        let truncated: Bool
    }

    static func listPlans(_ arguments: [String: Value]?, _ context: McpToolContext) async throws -> CallTool.Result {
        let snapshot = await context.snapshot()
        let project = try await optionalProject(arguments, snapshot: snapshot, configService: context.configService)
        let maxCount = limit(arguments)
        let fromDate = string(arguments, "from").flatMap(parseDay)
        let toDate = string(arguments, "to").flatMap(parseDay).map {
            Calendar.current.date(byAdding: .day, value: 1, to: $0) ?? $0
        }

        var plans = await context.plansService.loadPlans()
        if let project {
            // Same matching the dashboard's global filter uses: projectHint
            // against the project display name, case-insensitive.
            let name = project.name.lowercased()
            plans = plans.filter { ($0.projectHint ?? "").lowercased().contains(name) }
        }
        if fromDate != nil || toDate != nil {
            plans = plans.filter { plan in
                guard let created = plan.createdAt else { return false }
                if let fromDate, created < fromDate { return false }
                if let toDate, created >= toDate { return false }
                return true
            }
        }

        let iso = ISO8601DateFormatter()
        let plansDir = context.claudeDir.appendingPathComponent("plans")
        return encodeJSON(PlanListResponse(
            plans: plans.prefix(maxCount).map { plan in
                PlanEntry(
                    filename: plan.filename,
                    title: plan.title,
                    projectHint: plan.projectHint,
                    createdAt: plan.createdAt.map(iso.string),
                    sizeBytes: plan.sizeBytes,
                    file: plansDir.appendingPathComponent(plan.filename).path
                )
            },
            truncated: plans.count > maxCount
        ))
    }
}
