import SwiftUI

/// 1200×630 export of a session trace: stats and the lanes, no transcript
/// text and no agent descriptions, so the image is safe to post as-is.
struct TraceShareCard: View {
    let trace: SessionTrace
    let projectName: String
    let collapsesGaps: Bool

    static let size = CGSize(width: 1200, height: 630)
    private static let margin: CGFloat = 48

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy, HH:mm"
        return f
    }()

    var body: some View {
        let axis = TraceTimeAxis(trace: trace, collapsesGaps: collapsesGaps)
        let layout = TraceLayout.make(trace: trace, width: Self.size.width - Self.margin * 2, height: 340)
        let renderer = TraceRenderer(trace: trace, axis: axis, layout: layout, palette: .card)

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(projectName)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Claude Code session · \(Self.dateFormatter.string(from: trace.start))")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.6))
                }
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Claudoscope")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(Color.white.opacity(0.85))
            }

            Spacer(minLength: 20)

            Canvas { context, _ in
                renderer.draw(in: &context)
            }
            .frame(width: Self.size.width - Self.margin * 2, height: layout.height)

            Spacer(minLength: 20)

            HStack(spacing: 0) {
                tile("Duration", TraceRenderer.longDuration(trace.activeDuration))
                tile("Turns", "\(trace.userTurns.count)")
                tile("Tool calls", "\(trace.toolCalls.count)")
                tile("Agents", "\(trace.agentSpans.count)")
                tile("Compactions", "\(trace.compactions.count)")
                tile("Cost", formatCost(trace.totalCost))
                tile("Model", modelLabel)
            }
        }
        .padding(Self.margin)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(
            LinearGradient(
                colors: [Color(red: 0.086, green: 0.094, blue: 0.114), Color(red: 0.043, green: 0.047, blue: 0.063)],
                startPoint: .top, endPoint: .bottom
            )
        )
    }

    private var modelLabel: String {
        let families = trace.models.map { getModelFamily($0).capitalized }
        var seen: [String] = []
        for family in families where !seen.contains(family) { seen.append(family) }
        return seen.isEmpty ? "—" : seen.joined(separator: " + ")
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.5))
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
