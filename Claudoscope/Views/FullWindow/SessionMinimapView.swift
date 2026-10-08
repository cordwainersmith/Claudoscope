import SwiftUI

/// One clickable strip showing the whole session's anatomy: turns, tool calls
/// by category, errors, blocked actions, compactions, subagent spawns and
/// bookmarks. Drawn with Canvas because a session can have thousands of
/// records and per-record Charts marks are too slow. The x axis is record
/// index, not time, so idle gaps do not compress the active parts and a click
/// maps directly onto a chat row anchor.
struct SessionMinimapView: View {
    let events: [MinimapEvent]
    let recordCount: Int
    /// Called with the record index to scroll to.
    let onJump: (Int) -> Void

    @State private var hoverIndex: Int? = nil
    @State private var hoverX: CGFloat = 0

    private static let height: CGFloat = 36
    private static let laneHeight: CGFloat = 10
    private static let horizontalPadding: CGFloat = 24
    private static let hitSlop: CGFloat = 4

    var body: some View {
        if events.count < 2 {
            EmptyView()
        } else {
            GeometryReader { geo in
                let width = max(geo.size.width - Self.horizontalPadding * 2, 1)
                Canvas { context, _ in
                    draw(in: &context, width: width)
                }
                .padding(.horizontal, Self.horizontalPadding)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hoverX = location.x
                        hoverIndex = nearestEvent(toX: location.x - Self.horizontalPadding, width: width)
                    case .ended:
                        hoverIndex = nil
                    }
                }
                .onTapGesture(count: 1, coordinateSpace: .local) { location in
                    if let index = nearestEvent(toX: location.x - Self.horizontalPadding, width: width) {
                        onJump(events[index].recordIndex)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let index = hoverIndex, events.indices.contains(index) {
                        tooltip(for: events[index], containerWidth: geo.size.width)
                    }
                }
            }
            .frame(height: Self.height)
            .background(.bar)
            .accessibilityLabel("Session minimap")
        }
    }

    // MARK: - Drawing

    private func x(for recordIndex: Int, width: CGFloat) -> CGFloat {
        CGFloat(recordIndex) / CGFloat(max(recordCount - 1, 1)) * width
    }

    private func laneTop(_ lane: Int) -> CGFloat {
        (Self.height - Self.laneHeight * 3) / 2 + CGFloat(lane) * Self.laneHeight
    }

    private func draw(in context: inout GraphicsContext, width: CGFloat) {
        for event in events {
            let px = x(for: event.recordIndex, width: width)
            let lane = SessionMinimap.lane(for: event.kind)
            let top = laneTop(lane)
            switch event.kind {
            case .userTurn:
                let rect = CGRect(x: px - 0.5, y: top + 2, width: 1, height: Self.laneHeight - 4)
                context.fill(Path(rect), with: .color(.secondary))
            case .assistantTurn:
                let rect = CGRect(x: px - 0.5, y: top + 2, width: 1, height: Self.laneHeight - 4)
                context.fill(Path(rect), with: .color(.okabeBlue))
            case .toolCall(let category):
                let rect = CGRect(x: px - 1, y: top + 1, width: 2, height: Self.laneHeight - 2)
                context.fill(Path(rect), with: .color(Self.color(for: category)))
            case .toolError:
                square(&context, x: px, top: top, color: .okabeVermillion)
            case .blocked:
                square(&context, x: px, top: top, color: .okabePurple)
            case .compaction:
                square(&context, x: px, top: top, color: .okabeOrange)
            case .subagentSpawn:
                square(&context, x: px, top: top, color: .okabeBluishGreen)
            case .bookmark:
                var path = Path()
                let y = top - 1
                path.move(to: CGPoint(x: px, y: y + 4))
                path.addLine(to: CGPoint(x: px - 2.5, y: y))
                path.addLine(to: CGPoint(x: px + 2.5, y: y))
                path.closeSubpath()
                context.fill(path, with: .color(.okabeOrange))
            }
        }
    }

    private func square(_ context: inout GraphicsContext, x: CGFloat, top: CGFloat, color: Color) {
        let side: CGFloat = 3
        let rect = CGRect(x: x - side / 2, y: top + (Self.laneHeight - side) / 2 + 1, width: side, height: side)
        context.fill(Path(rect), with: .color(color))
    }

    private static func color(for category: ToolCategory) -> Color {
        switch category {
        case .read: return categoryColor(for: "Read")
        case .write: return categoryColor(for: "Write")
        case .exec: return categoryColor(for: "Bash")
        case .other: return .secondary
        }
    }

    // MARK: - Hit testing

    /// Nearest event within the hit slop, preferring the markers lane, then
    /// tools, then turns, so a small error square under a dense tool run is
    /// still reachable.
    private func nearestEvent(toX pointX: CGFloat, width: CGFloat) -> Int? {
        var best: (index: Int, lane: Int, distance: CGFloat)? = nil
        for (i, event) in events.enumerated() {
            let distance = abs(x(for: event.recordIndex, width: width) - pointX)
            guard distance <= Self.hitSlop else { continue }
            let lane = SessionMinimap.lane(for: event.kind)
            if let current = best {
                if lane > current.lane || (lane == current.lane && distance < current.distance) {
                    best = (i, lane, distance)
                }
            } else {
                best = (i, lane, distance)
            }
        }
        return best?.index
    }

    /// 1-based ordinal of the user turn this event belongs to.
    private func turnNumber(for event: MinimapEvent) -> Int {
        events.reduce(0) { count, other in
            other.kind == .userTurn && other.recordIndex <= event.recordIndex ? count + 1 : count
        }
    }

    // MARK: - Tooltip

    private func tooltip(for event: MinimapEvent, containerWidth: CGFloat) -> some View {
        let turn = turnNumber(for: event)
        let label = Text(event.label)
            .font(.system(size: 11))
            .lineLimit(1)
            .truncationMode(.middle)
        return HStack(spacing: 6) {
            if turn > 0 {
                Text("Turn \(turn)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            label
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .frame(maxWidth: 360, alignment: .leading)
        .fixedSize()
        .offset(x: min(max(hoverX - 40, 4), max(containerWidth - 200, 4)), y: -22)
        .allowsHitTesting(false)
    }
}
