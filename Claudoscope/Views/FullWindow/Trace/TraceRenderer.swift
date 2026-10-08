import SwiftUI

/// Where each lane sits for a given width. Shared by the live Trace tab and
/// the share card so both draw the same picture.
struct TraceLayout: Equatable {
    enum Lane: Equatable {
        case axis, you, claude, tool(ToolCategory), agents, context, cost
    }

    struct Row: Equatable {
        let lane: Lane
        let title: String
        let rect: CGRect
    }

    let rows: [Row]
    let plotX: CGFloat
    let plotWidth: CGFloat
    let height: CGFloat

    static let gutter: CGFloat = 72
    static let rightPad: CGFloat = 60
    static let agentRowHeight: CGFloat = 12
    static let maxAgentRows = 5

    var plotMaxX: CGFloat { plotX + plotWidth }
    var plotTop: CGFloat { rows.first?.rect.minY ?? 0 }
    var plotBottom: CGFloat { rows.last?.rect.maxY ?? height }

    func row(_ lane: Lane) -> Row? { rows.first { $0.lane == lane } }

    /// Vertical pitch between agent rows once the lane has been scaled.
    static func agentRowPitch(in rect: CGRect, trace: SessionTrace) -> CGFloat {
        let rows = max(min(trace.agentRowCount, maxAgentRows), 1)
        return (rect.height - 8) / CGFloat(rows)
    }

    /// Base lane heights; `make(trace:width:height:)` grows them to fill a
    /// taller panel, giving most of the extra room to Context and Cost.
    private static let axisHeight: CGFloat = 20
    private static let youHeight: CGFloat = 16
    private static let claudeHeight: CGFloat = 20
    private static let toolHeight: CGFloat = 14
    private static let contextHeight: CGFloat = 56
    private static let costHeight: CGFloat = 44
    private static let laneGap: CGFloat = 2
    private static let maxLaneScale: CGFloat = 1.75

    static func make(trace: SessionTrace, width: CGFloat, height: CGFloat? = nil) -> TraceLayout {
        var rows: [Row] = []
        var y: CGFloat = 0
        let plotX = gutter
        let plotWidth = max(width - gutter - rightPad, 40)

        let categories: [ToolCategory] = [.read, .write, .exec, .other].filter { category in
            category != .other || trace.toolCalls.contains { $0.category == .other }
        }
        let agentRows = trace.agentSpans.isEmpty ? 0 : min(trace.agentRowCount, maxAgentRows)
        let agentsHeight: CGFloat = agentRows == 0 ? 0 : 8 + CGFloat(agentRows) * agentRowHeight

        // Fixed lanes scale up a little; Context and Cost absorb the rest.
        var fixedTotal = axisHeight + youHeight + claudeHeight + CGFloat(categories.count) * toolHeight + agentsHeight
        let laneCount = 5 + categories.count + (agentRows == 0 ? 0 : 1)
        let gapsTotal = CGFloat(laneCount) * laneGap + 4
        let baseTotal = fixedTotal + contextHeight + costHeight + gapsTotal
        var scale: CGFloat = 1
        var contextH = contextHeight
        var costH = costHeight
        if let height, height > baseTotal {
            scale = min(height / baseTotal, maxLaneScale)
            fixedTotal *= scale
            let remaining = max(height - fixedTotal - gapsTotal, contextHeight + costHeight)
            contextH = (remaining * 0.6).rounded()
            costH = remaining - contextH
        }

        func add(_ lane: Lane, _ title: String, _ h: CGFloat) {
            rows.append(Row(lane: lane, title: title, rect: CGRect(x: plotX, y: y, width: plotWidth, height: h.rounded())))
            y += h.rounded() + laneGap
        }

        add(.axis, "", axisHeight * scale)
        add(.you, "You", youHeight * scale)
        add(.claude, "Claude", claudeHeight * scale)
        for category in categories {
            add(.tool(category), category.label, toolHeight * scale)
        }
        if agentRows > 0 {
            add(.agents, "Agents", agentsHeight * scale)
        }
        add(.context, "Context", contextH)
        add(.cost, "Cost", costH)

        return TraceLayout(rows: rows, plotX: plotX, plotWidth: plotWidth, height: y + 4)
    }
}

/// Explicit colors so the same renderer works inside the app (dynamic colors)
/// and in the share image (fixed dark palette, no environment to resolve).
struct TracePalette {
    var label: Color
    var grid: Color
    var gapFill: Color
    var user: Color
    var claude: Color = .okabeBlue
    var agent: Color = .okabeBluishGreen
    var context: Color = .okabeOrange
    var cost: Color = .okabePurple
    var compaction: Color = .okabeVermillion
    var error: Color = .okabeVermillion
    var blocked: Color = .okabePurple
    var reveal: Color
    var showsAgentLabels: Bool

    static let panel = TracePalette(
        label: .secondary,
        grid: Color.primary.opacity(0.08),
        gapFill: Color.primary.opacity(0.05),
        user: Color.primary.opacity(0.7),
        reveal: Color(nsColor: .windowBackgroundColor).opacity(0.78),
        showsAgentLabels: true
    )

    static let card = TracePalette(
        label: Color.white.opacity(0.62),
        grid: Color.white.opacity(0.1),
        gapFill: Color.white.opacity(0.06),
        user: Color.white.opacity(0.85),
        claude: .okabeSkyBlue,
        reveal: .clear,
        showsAgentLabels: false
    )

    func tool(_ category: ToolCategory) -> Color {
        switch category {
        case .read: return categoryColor(for: "Read")
        case .write: return categoryColor(for: "Write")
        case .exec: return categoryColor(for: "Bash")
        case .other: return label
        }
    }
}

/// Draws a `SessionTrace` into a Canvas. Pure drawing: hover, selection and the
/// playhead line are overlays in the view so moving the mouse never redraws
/// thousands of tool marks. The reveal shade is the one playhead-dependent
/// part and is cheap (one rect).
struct TraceRenderer {
    let trace: SessionTrace
    let axis: TraceTimeAxis
    let layout: TraceLayout
    let palette: TracePalette
    /// Fraction of the axis revealed during replay; nil shows everything.
    var reveal: Double? = nil

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f
    }()

    func x(_ date: Date) -> CGFloat {
        layout.plotX + CGFloat(axis.fraction(of: date)) * layout.plotWidth
    }

    func x(fraction: Double) -> CGFloat {
        layout.plotX + CGFloat(fraction) * layout.plotWidth
    }

    func draw(in context: inout GraphicsContext) {
        drawLaneBackgrounds(&context)
        drawGaps(&context)
        drawAxis(&context)
        drawUserTurns(&context)
        drawClaudeSpans(&context)
        drawToolCalls(&context)
        drawAgents(&context)
        drawContext(&context)
        drawCost(&context)
        drawReveal(&context)
    }

    // MARK: - Chrome

    private func drawLaneBackgrounds(_ context: inout GraphicsContext) {
        for row in layout.rows {
            if case .axis = row.lane { continue }
            if case .tool = row.lane {
                context.fill(Path(row.rect), with: .color(palette.grid.opacity(0.5)))
            }
            let label = Text(row.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(palette.label)
            context.draw(label, at: CGPoint(x: 8, y: row.rect.midY), anchor: .leading)
            var line = Path()
            line.move(to: CGPoint(x: layout.plotX, y: row.rect.maxY + 1))
            line.addLine(to: CGPoint(x: layout.plotMaxX, y: row.rect.maxY + 1))
            context.stroke(line, with: .color(palette.grid), lineWidth: 0.5)
        }
    }

    private func drawGaps(_ context: inout GraphicsContext) {
        guard let axisRow = layout.row(.axis) else { return }
        for (gap, range) in axis.gapFractions {
            let x1 = x(fraction: range.lowerBound)
            let x2 = x(fraction: range.upperBound)
            let rect = CGRect(x: x1, y: layout.plotTop, width: max(x2 - x1, 1), height: layout.plotBottom - layout.plotTop)
            context.fill(Path(rect), with: .color(palette.gapFill))
            var edges = Path()
            for edgeX in [x1, x2] {
                edges.move(to: CGPoint(x: edgeX, y: layout.plotTop))
                edges.addLine(to: CGPoint(x: edgeX, y: layout.plotBottom))
            }
            context.stroke(edges, with: .color(palette.grid), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            let label = Text("⋯ \(Self.shortDuration(gap.duration))")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(palette.label)
            context.draw(label, at: CGPoint(x: (x1 + x2) / 2, y: axisRow.rect.midY), anchor: .center)
        }
    }

    private func drawAxis(_ context: inout GraphicsContext) {
        guard let axisRow = layout.row(.axis) else { return }
        let tickCount = max(Int(layout.plotWidth / 110), 1)
        // A tick label under a gap marker is unreadable; the gap label wins.
        let gapCenters = axis.gapFractions.map { x(fraction: ($0.range.lowerBound + $0.range.upperBound) / 2) }
        var lastDay: String?
        for i in 0...tickCount {
            let fraction = Double(i) / Double(tickCount)
            let px = x(fraction: fraction)
            if gapCenters.contains(where: { abs($0 - px) < 48 }) { continue }
            let date = axis.date(atFraction: fraction)
            var tick = Path()
            tick.move(to: CGPoint(x: px, y: axisRow.rect.maxY - 4))
            tick.addLine(to: CGPoint(x: px, y: axisRow.rect.maxY))
            context.stroke(tick, with: .color(palette.label), lineWidth: 1)
            var grid = Path()
            grid.move(to: CGPoint(x: px, y: axisRow.rect.maxY))
            grid.addLine(to: CGPoint(x: px, y: layout.plotBottom))
            context.stroke(grid, with: .color(palette.grid), lineWidth: 0.5)

            let day = Self.dayFormatter.string(from: date)
            var text = Self.timeFormatter.string(from: date)
            if lastDay != nil && day != lastDay { text = "\(day) \(text)" }
            lastDay = day
            let anchor: UnitPoint = i == 0 ? .bottomLeading : (i == tickCount ? .bottomTrailing : .bottom)
            let label = Text(text)
                .font(.system(size: 9, design: .rounded))
                .foregroundStyle(palette.label)
            context.draw(label, at: CGPoint(x: px, y: axisRow.rect.maxY - 6), anchor: anchor)
        }
    }

    // MARK: - Lanes

    private func drawUserTurns(_ context: inout GraphicsContext) {
        guard let row = layout.row(.you) else { return }
        for turn in trace.userTurns {
            let px = x(turn.time)
            let rect = CGRect(x: px - 0.75, y: row.rect.minY + 2, width: 1.5, height: row.rect.height - 4)
            context.fill(Path(rect), with: .color(palette.user))
        }
    }

    private func drawClaudeSpans(_ context: inout GraphicsContext) {
        guard let row = layout.row(.claude) else { return }
        for span in trace.claudeSpans {
            let x1 = x(span.start)
            let x2 = max(x(span.end), x1 + 2)
            let rect = CGRect(x: x1, y: row.rect.minY + 3, width: x2 - x1, height: row.rect.height - 6)
            context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(palette.claude.opacity(0.85)))
        }
    }

    private func drawToolCalls(_ context: inout GraphicsContext) {
        for call in trace.toolCalls {
            guard let row = layout.row(.tool(call.category)) else { continue }
            let px = x(call.time)
            if call.isBlocked || call.isError {
                let side: CGFloat = 6
                let rect = CGRect(x: px - side / 2, y: row.rect.midY - side / 2, width: side, height: side)
                if call.isBlocked {
                    context.fill(Path(rect), with: .color(palette.blocked))
                } else {
                    context.fill(Path(rect), with: .color(palette.error.opacity(0.25)))
                    context.stroke(Path(rect), with: .color(palette.error), lineWidth: 1)
                }
            } else {
                let barWidth: CGFloat = row.rect.height >= 20 ? 3 : 2
                let rect = CGRect(x: px - barWidth / 2, y: row.rect.minY + 2, width: barWidth, height: row.rect.height - 4)
                context.fill(Path(rect), with: .color(palette.tool(call.category)))
            }
        }
    }

    private func drawAgents(_ context: inout GraphicsContext) {
        guard let row = layout.row(.agents), let claudeRow = layout.row(.claude) else { return }
        let rowHeight = TraceLayout.agentRowPitch(in: row.rect, trace: trace)
        for span in trace.agentSpans {
            let shownRow = min(span.row, TraceLayout.maxAgentRows - 1)
            let y = row.rect.minY + 4 + CGFloat(shownRow) * rowHeight + rowHeight / 2
            let x1 = x(span.start)
            let x2 = span.end.map { max(x($0), x1 + 2) } ?? layout.plotMaxX

            var fork = Path()
            fork.move(to: CGPoint(x: x1, y: claudeRow.rect.maxY))
            fork.addLine(to: CGPoint(x: x1, y: y))
            context.stroke(fork, with: .color(palette.agent.opacity(0.35)), lineWidth: 1)

            var line = Path()
            line.move(to: CGPoint(x: x1, y: y))
            line.addLine(to: CGPoint(x: x2, y: y))
            context.stroke(line, with: .color(palette.agent), lineWidth: 2)
            context.fill(Path(ellipseIn: CGRect(x: x1 - 2.5, y: y - 2.5, width: 5, height: 5)), with: .color(palette.agent))
            if span.end != nil {
                context.fill(Path(CGRect(x: x2 - 1, y: y - 3, width: 1.5, height: 6)), with: .color(palette.agent))
            }

            let available = x2 - x1 - 10
            if palette.showsAgentLabels, available >= 28 {
                let label = Text(span.label)
                    .font(.system(size: 9))
                    .foregroundStyle(palette.label)
                let rect = CGRect(x: x1 + 7, y: y - 6, width: min(available, 200), height: 12)
                context.draw(label, in: rect)
            }
        }
    }

    private func drawContext(_ context: inout GraphicsContext) {
        guard let row = layout.row(.context) else { return }
        let top = row.rect.minY + 4
        let bottom = row.rect.maxY - 2
        let height = bottom - top

        var ceiling = Path()
        ceiling.move(to: CGPoint(x: layout.plotX, y: top))
        ceiling.addLine(to: CGPoint(x: layout.plotMaxX, y: top))
        context.stroke(ceiling, with: .color(palette.grid), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

        let points = trace.contextPoints
        if let first = points.first {
            var line = Path()
            var area = Path()
            let startX = x(first.time)
            let startY = bottom - CGFloat(min(first.utilization, 1)) * height
            line.move(to: CGPoint(x: startX, y: startY))
            area.move(to: CGPoint(x: startX, y: bottom))
            area.addLine(to: CGPoint(x: startX, y: startY))
            for point in points.dropFirst() {
                let px = x(point.time)
                let py = bottom - CGFloat(min(point.utilization, 1)) * height
                line.addLine(to: CGPoint(x: px, y: py))
                area.addLine(to: CGPoint(x: px, y: py))
            }
            let endX = x(points[points.count - 1].time)
            area.addLine(to: CGPoint(x: endX, y: bottom))
            area.closeSubpath()
            context.fill(area, with: .color(palette.context.opacity(0.22)))
            context.stroke(line, with: .color(palette.context), lineWidth: 1.25)
        }

        for compaction in trace.compactions {
            let px = x(compaction.time)
            var cut = Path()
            cut.move(to: CGPoint(x: px, y: top))
            cut.addLine(to: CGPoint(x: px, y: bottom))
            context.stroke(cut, with: .color(palette.compaction), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            let scissors = Text(Image(systemName: "scissors"))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(palette.compaction)
            context.draw(scissors, at: CGPoint(x: px, y: top - 1), anchor: .bottom)
        }

        let pct = Text("100%")
            .font(.system(size: 8, design: .rounded))
            .foregroundStyle(palette.label)
        context.draw(pct, at: CGPoint(x: layout.plotMaxX + 4, y: top), anchor: .leading)
    }

    private func drawCost(_ context: inout GraphicsContext) {
        guard let row = layout.row(.cost) else { return }
        let top = row.rect.minY + 6
        let bottom = row.rect.maxY - 4
        let height = bottom - top
        let total = max(trace.totalCost, 0.000001)

        var line = Path()
        line.move(to: CGPoint(x: layout.plotX, y: bottom))
        var lastY = bottom
        for point in trace.costPoints {
            let px = x(point.time)
            let py = bottom - CGFloat(point.cumulative / total) * height
            line.addLine(to: CGPoint(x: px, y: lastY))
            line.addLine(to: CGPoint(x: px, y: py))
            lastY = py
        }
        line.addLine(to: CGPoint(x: layout.plotMaxX, y: lastY))
        context.stroke(line, with: .color(palette.cost), lineWidth: 1.5)

        let endLabel = Text(formatCost(trace.totalCost))
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(palette.cost)
        context.draw(endLabel, at: CGPoint(x: layout.plotMaxX + 4, y: lastY), anchor: .leading)
    }

    private func drawReveal(_ context: inout GraphicsContext) {
        guard let reveal, reveal < 1 else { return }
        let px = x(fraction: reveal)
        let rect = CGRect(x: px, y: layout.plotTop, width: layout.plotMaxX - px, height: layout.plotBottom - layout.plotTop)
        context.fill(Path(rect), with: .color(palette.reveal))
    }

    // MARK: - Formatting

    static func shortDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m" }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours < 24 { return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m" }
        let days = hours / 24
        return "\(days)d \(hours % 24)h"
    }

    static func longDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        if m > 0 { return String(format: "%dm %02ds", m, s) }
        return "\(s)s"
    }
}
