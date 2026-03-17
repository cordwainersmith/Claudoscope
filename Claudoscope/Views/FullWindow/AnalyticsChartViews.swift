import SwiftUI
import Charts

// MARK: - Daily Usage Chart

struct DailyUsageChartView: View {
    let dailyUsage: [DailyUsage]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            IOTokensChartView(dailyUsage: dailyUsage)
            CacheTokensChartView(dailyUsage: dailyUsage)
        }
    }
}

struct IOTokensChartView: View {
    let dailyUsage: [DailyUsage]
    @State private var hoveredDate: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Input & Output Tokens")
                .font(.system(size: 13, weight: .medium))

            Chart(dailyUsage) { day in
                BarMark(
                    x: .value("Date", day.date),
                    y: .value("Tokens", day.inputTokens)
                )
                .foregroundStyle(by: .value("Type", "Input"))
                .opacity(hoveredDate == nil || hoveredDate == day.date ? 1.0 : 0.4)

                BarMark(
                    x: .value("Date", day.date),
                    y: .value("Tokens", day.outputTokens)
                )
                .foregroundStyle(by: .value("Type", "Output"))
                .opacity(hoveredDate == nil || hoveredDate == day.date ? 1.0 : 0.4)
            }
            .chartForegroundStyleScale([
                "Input": Color.blue.opacity(0.7),
                "Output": Color.green.opacity(0.7),
            ])
            .dailyChartAxes()
            .chartLegend(position: .bottom, spacing: 16)
            .frame(height: 180)
            .chartOverlay { proxy in
                chartHoverOverlay(proxy: proxy) { date in
                    hoveredDate = date
                }
            }
            .overlay(alignment: .topLeading) {
                if let date = hoveredDate,
                   let day = dailyUsage.first(where: { $0.date == date }) {
                    ChartTooltip(items: [
                        ("Input", formatTokens(day.inputTokens), .blue),
                        ("Output", formatTokens(day.outputTokens), .green),
                    ], date: formatChartDate(date))
                    .padding(8)
                }
            }
            .frame(maxWidth: 800)
            .padding(16)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1))
            .frame(maxWidth: .infinity)
        }
    }
}

struct CacheTokensChartView: View {
    let dailyUsage: [DailyUsage]
    @State private var hoveredDate: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cache Tokens")
                .font(.system(size: 13, weight: .medium))

            Chart(dailyUsage) { day in
                BarMark(
                    x: .value("Date", day.date),
                    y: .value("Tokens", day.cacheReadTokens)
                )
                .foregroundStyle(by: .value("Type", "Cache Read"))
                .opacity(hoveredDate == nil || hoveredDate == day.date ? 1.0 : 0.4)

                BarMark(
                    x: .value("Date", day.date),
                    y: .value("Tokens", day.cacheCreationTokens)
                )
                .foregroundStyle(by: .value("Type", "Cache Write"))
                .opacity(hoveredDate == nil || hoveredDate == day.date ? 1.0 : 0.4)
            }
            .chartForegroundStyleScale([
                "Cache Read": Color.purple.opacity(0.5),
                "Cache Write": Color.orange.opacity(0.6),
            ])
            .dailyChartAxes()
            .chartLegend(position: .bottom, spacing: 16)
            .frame(height: 180)
            .chartOverlay { proxy in
                chartHoverOverlay(proxy: proxy) { date in
                    hoveredDate = date
                }
            }
            .overlay(alignment: .topLeading) {
                if let date = hoveredDate,
                   let day = dailyUsage.first(where: { $0.date == date }) {
                    ChartTooltip(items: [
                        ("Cache Read", formatTokens(day.cacheReadTokens), .purple),
                        ("Cache Write", formatTokens(day.cacheCreationTokens), .orange),
                    ], date: formatChartDate(date))
                    .padding(8)
                }
            }
            .frame(maxWidth: 800)
            .padding(16)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1))
            .frame(maxWidth: .infinity)
        }
    }
}

func chartHoverOverlay(proxy: ChartProxy, onDateChange: @escaping (String?) -> Void) -> some View {
    GeometryReader { geo in
        Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    if let plotFrame = proxy.plotFrame {
                        let origin = geo[plotFrame].origin
                        let adjustedX = location.x - origin.x
                        if let date: String = proxy.value(atX: adjustedX) {
                            onDateChange(date)
                        }
                    }
                case .ended:
                    onDateChange(nil)
                }
            }
    }
}

struct ChartTooltip: View {
    let items: [(label: String, value: String, color: Color)]
    let date: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(date)
                .font(Typography.caption)
                .foregroundStyle(.secondary)

            ForEach(items, id: \.label) { item in
                HStack(spacing: 6) {
                    Circle()
                        .fill(item.color.opacity(0.7))
                        .frame(width: 6, height: 6)
                    Text(item.label)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(item.value)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                }
            }
        }
        .padding(8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary, lineWidth: 1))
    }
}

extension View {
    func dailyChartAxes() -> some View {
        self
            .chartXAxis {
                AxisMarks(values: .automatic) { value in
                    AxisValueLabel {
                        if let str = value.as(String.self) {
                            Text(formatChartDate(str))
                                .font(.system(size: 11))
                        }
                    }
                    AxisGridLine()
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisValueLabel {
                        if let intVal = value.as(Int.self) {
                            Text(formatTokens(intVal))
                                .font(.system(size: 11))
                        }
                    }
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4, 4]))
                }
            }
    }
}

func formatChartDate(_ dateStr: String) -> String {
    // "2026-03-14" -> "3/14" or day-of-week abbreviation
    let parts = dateStr.split(separator: "-")
    guard parts.count == 3,
          let month = Int(parts[1]),
          let day = Int(parts[2]) else { return dateStr }
    return "\(month)/\(day)"
}
