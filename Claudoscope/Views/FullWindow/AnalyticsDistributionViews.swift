import SwiftUI

// MARK: - Cost by Project

struct CostByProjectView: View {
    let projectCosts: [ProjectCost]
    let totalCost: Double

    private let barColors: [Color] = [
        .blue, .green, .orange, .red, .purple, .cyan, .yellow, .pink, .mint, .teal
    ]

    var topProjects: [ProjectCost] {
        Array(projectCosts.prefix(8))
    }

    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Cost by Project")
                    .font(.system(size: 13, weight: .medium))

                VStack(spacing: 8) {
                    ForEach(Array(topProjects.enumerated()), id: \.element.id) { index, project in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(project.projectName)
                                    .font(Typography.bodyMedium)
                                    .lineLimit(1)
                                Spacer()
                                Text(formatCost(project.totalCost))
                                    .font(Typography.code)
                                    .foregroundStyle(.secondary)
                                if totalCost > 0 {
                                    Text("\(Int((project.totalCost / totalCost) * 100))%")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 30, alignment: .trailing)
                                }
                            }

                            GeometryReader { geo in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(barColors[index % barColors.count].opacity(0.6))
                                    .frame(width: max(4, geo.size.width * (totalCost > 0 ? project.totalCost / totalCost : 0)))
                            }
                            .frame(height: 4)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Cost by Category

struct CostByCategoryView: View {
    let costByCategory: [ToolCostCategory: Double]
    let fastModeTurnCount: Int

    private func label(_ c: ToolCostCategory) -> String {
        switch c {
        case .mcp: return "MCP tools"
        case .subagent: return "Subagents"
        case .other: return "Other"
        }
    }

    private func color(_ c: ToolCostCategory) -> Color {
        switch c {
        case .mcp: return .purple
        case .subagent: return .orange
        case .other: return .blue
        }
    }

    private var rows: [(category: ToolCostCategory, cost: Double)] {
        costByCategory
            .map { (category: $0.key, cost: $0.value) }
            .sorted { $0.cost > $1.cost }
    }

    private var total: Double { costByCategory.values.reduce(0, +) }

    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Cost by Category")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    if fastModeTurnCount > 0 {
                        Text("\(fastModeTurnCount) fast-mode turn\(fastModeTurnCount == 1 ? "" : "s")")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .help("Billed assistant turns whose usage.speed was non-standard. Fast mode bills at the 2x rate.")
                    }
                }

                VStack(spacing: 8) {
                    ForEach(rows, id: \.category) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(label(row.category))
                                    .font(Typography.bodyMedium)
                                Spacer()
                                Text(formatCost(row.cost))
                                    .font(Typography.code)
                                    .foregroundStyle(.secondary)
                                if total > 0 {
                                    Text("\(Int((row.cost / total) * 100))%")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 30, alignment: .trailing)
                                }
                            }
                            GeometryReader { geo in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(color(row.category).opacity(0.6))
                                    .frame(width: max(4, geo.size.width * (total > 0 ? row.cost / total : 0)))
                            }
                            .frame(height: 4)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Model Distribution

struct ModelDistributionView: View {
    let modelUsage: [ModelUsage]

    private let pieColors: [Color] = [
        .purple, .blue, .green, .orange, .red, .cyan, .yellow, .pink
    ]

    var totalTurns: Int {
        modelUsage.reduce(0) { $0 + $1.turnCount }
    }

    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Model Distribution")
                    .font(.system(size: 13, weight: .medium))

                if modelUsage.isEmpty {
                    Text("No data")
                        .font(Typography.body)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 100)
                } else {
                    HStack(spacing: 24) {
                        // Donut chart
                        ZStack {
                            ForEach(Array(donutSlices().enumerated()), id: \.offset) { index, slice in
                                DonutSlice(
                                    startAngle: slice.start,
                                    endAngle: slice.end,
                                    color: pieColors[index % pieColors.count]
                                )
                            }
                            Circle()
                                .fill(.background)
                                .frame(width: 60, height: 60)
                        }
                        .frame(width: 100, height: 100)

                        // Legend
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(modelUsage.enumerated()), id: \.element.id) { index, usage in
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(pieColors[index % pieColors.count])
                                        .frame(width: 8, height: 8)
                                    Text(usage.model)
                                        .font(Typography.body)
                                    Spacer()
                                    if totalTurns > 0 {
                                        Text(String(format: "%.1f%%", Double(usage.turnCount) / Double(totalTurns) * 100))
                                            .font(Typography.code)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func donutSlices() -> [(start: Angle, end: Angle)] {
        guard totalTurns > 0 else { return [] }
        var slices: [(start: Angle, end: Angle)] = []
        var currentAngle = Angle.degrees(-90)
        for usage in modelUsage {
            let fraction = Double(usage.turnCount) / Double(totalTurns)
            let sweep = Angle.degrees(fraction * 360)
            slices.append((start: currentAngle, end: currentAngle + sweep))
            currentAngle = currentAngle + sweep
        }
        return slices
    }
}

struct DonutSlice: View {
    let startAngle: Angle
    let endAngle: Angle
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let radius = min(geo.size.width, geo.size.height) / 2
            Path { path in
                path.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
                path.addArc(center: center, radius: radius * 0.6, startAngle: endAngle, endAngle: startAngle, clockwise: true)
                path.closeSubpath()
            }
            .fill(color)
        }
    }
}
