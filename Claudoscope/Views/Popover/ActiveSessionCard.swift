import SwiftUI

/// Live sessions in the popover, joined with their Fleet state. The card
/// tints by the most urgent state on it, waiting rows come first, and the
/// header opens the Fleet rail.
struct ActiveSessionsCard: View {
    let agents: [FleetAgent]
    /// A wait went long or a waiting agent's cache is about to expire.
    let escalated: Bool
    /// Raises the agent's terminal tab (waiting, live CLI agents).
    let onFocus: (FleetAgent) -> Void
    /// Opens the agent's session in the dashboard.
    let onOpen: (FleetAgent) -> Void
    let onOpenFleet: () -> Void
    @State private var headerHovered = false

    private var needsYou: Int { agents.filter { $0.state.needsAttention }.count }
    private var blocked: Int { agents.filter { $0.state == .blockedOnPermission }.count }

    private var tint: Color {
        if blocked > 0 || escalated { return .red }
        if needsYou > 0 { return .orange }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onOpenFleet) {
                HStack(spacing: 6) {
                    Text(agents.count == 1 ? "ACTIVE SESSION" : "ACTIVE SESSIONS \u{00B7} \(agents.count)")
                        .font(Typography.sectionLabel)
                        .foregroundStyle(.secondary)
                        .tracking(0.5)
                    Spacer()
                    if needsYou > 0 {
                        Text(needsYou == 1 ? "1 needs you" : "\(needsYou) need you")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(tint)
                    } else {
                        PulsingDot(color: tint)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(headerHovered ? .secondary : .tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { headerHovered = $0 }
            .help("Open Fleet control")
            .padding(.bottom, 8)

            let rows = ForEach(Array(agents.enumerated()), id: \.element.id) { index, agent in
                if index > 0 {
                    Rectangle()
                        .fill(tint.opacity(0.1))
                        .frame(height: 1)
                        .padding(.vertical, 6)
                }
                ActiveSessionRow(agent: agent, onFocus: onFocus, onOpen: onOpen)
            }

            if agents.count > 4 {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        rows
                    }
                }
                .frame(maxHeight: 280)
            } else {
                rows
            }
        }
        .padding(12)
        .background(tint.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(tint.opacity(0.2), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .animation(.easeInOut(duration: 0.25), value: tint)
    }
}

private struct ActiveSessionRow: View {
    let agent: FleetAgent
    let onFocus: (FleetAgent) -> Void
    let onOpen: (FleetAgent) -> Void
    @State private var hovered = false

    private var session: SessionSummary { agent.summary }

    /// A live CLI agent waiting on you is answered in its terminal; anything
    /// else opens in the dashboard.
    private var focusesTerminal: Bool {
        agent.state.needsAttention && !agent.summary.isCowork && agent.isLive
    }

    private var stateColor: Color {
        switch agent.state {
        case .blockedOnPermission, .failed: return .red
        case .waitingOnUser: return .orange
        case .working: return .green
        case .idle, .done: return .secondary
        }
    }

    var body: some View {
        Button {
            focusesTerminal ? onFocus(agent) : onOpen(agent)
        } label: {
            content
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(focusesTerminal ? "Bring the terminal tab titled \(agent.focusNeedle) forward"
              : (agent.summary.isCowork ? "Open the Fleet board" : "Open this session"))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(session.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: focusesTerminal ? "terminal" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hovered ? .secondary : .quaternary)
            }

            HStack(spacing: 0) {
                Text(agent.projectName)
                    .lineLimit(1)
                if let name = agent.displayName {
                    Text(name)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(-1)
                        .padding(.leading, 6)
                }
                Spacer(minLength: 8)
                Text(formatCost(session.estimatedCost))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.orange)

                if let model = session.primaryModel {
                    Text(getModelFamily(model).capitalized)
                        .font(Typography.micro)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.12))
                        .clipShape(Capsule())
                        .padding(.leading, 6)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                stateLine
                Spacer()
                Label("\(session.messageCount)", systemImage: "bubble.left")
                Label(formatTokens(session.totalInputTokens + session.totalOutputTokens), systemImage: "arrow.left.arrow.right")
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .labelStyle(CompactLabelStyle())
        }
    }

    /// State word in its color; waiting rows add the reason and a live wait
    /// clock, which is the one thing the popover should make you act on.
    @ViewBuilder
    private var stateLine: some View {
        switch agent.state {
        case .blockedOnPermission, .waitingOnUser:
            TimelineView(Tower.secondTick) { context in
                let tint = agent.isEscalated(now: context.date) ? Color.red : stateColor
                HStack(spacing: 4) {
                    Circle().fill(tint).frame(width: 5, height: 5)
                    Text(agent.state == .blockedOnPermission ? "Blocked" : "Waiting")
                        .foregroundStyle(tint)
                    Text(Tower.clock(from: agent.since, to: context.date))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                    if agent.isCacheAboutToExpire(now: context.date) {
                        Text("\u{00B7} cache expiring")
                            .foregroundStyle(tint)
                            .fixedSize()
                    }
                    if case .waitingOnUser(let reason) = agent.state {
                        Text("\u{00B7} \(reason)")
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(-1)
                    }
                }
            }
        default:
            HStack(spacing: 4) {
                Circle().fill(stateColor).frame(width: 5, height: 5)
                Text(agent.state.label)
                    .foregroundStyle(agent.state == .working ? AnyShapeStyle(stateColor) : AnyShapeStyle(.tertiary))
            }
        }
    }
}

private struct PulsingDot: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.windowIsVisible) private var windowIsVisible

    /// Pauses while the popover is closed: its view tree stays alive
    /// off-screen and a repeatForever animation there kept rendering.
    private var pulsing: Bool { !reduceMotion && windowIsVisible }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .opacity(reduceMotion ? 0.7 : (pulsing ? 0.4 : 1.0))
            .animation(
                pulsing ? .easeInOut(duration: 1.5).repeatForever(autoreverses: true) : .default,
                value: pulsing
            )
    }
}

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}
