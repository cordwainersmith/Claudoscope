import SwiftUI
import Charts

struct SparklineChart: View {
    let dailyUsage: [DailyUsage]

    private var last7Days: [DailyUsage] {
        let sorted = dailyUsage.sorted { $0.date < $1.date }
        return Array(sorted.suffix(7))
    }

    var body: some View {
        if last7Days.isEmpty {
            Rectangle()
                .fill(.quaternary)
                .frame(height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .padding(.horizontal, 16)
        } else {
            Chart(last7Days) { day in
                AreaMark(
                    x: .value("Date", day.date),
                    y: .value("Tokens", day.inputTokens + day.outputTokens)
                )
                .foregroundStyle(
                    .linearGradient(
                        colors: [.purple.opacity(0.3), .purple.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("Date", day.date),
                    y: .value("Tokens", day.inputTokens + day.outputTokens)
                )
                .foregroundStyle(.purple)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 32)
            .padding(.horizontal, 16)
        }
    }
}
