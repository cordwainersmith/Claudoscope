import SwiftUI

// MARK: - State colors

enum FleetStateStyle {
    static func color(_ state: FleetState) -> Color {
        switch state {
        case .blockedOnPermission: return .okabeVermillion
        case .waitingOnUser: return .okabeOrange
        case .working: return .okabeBlue
        case .idle: return .okabeGray
        case .failed: return .okabeVermillion
        case .done: return .okabeBluishGreen
        }
    }

    static let filterOrder: [(key: String, label: String, color: Color)] = [
        ("blocked", "Blocked", .okabeVermillion),
        ("waiting", "Waiting", .okabeOrange),
        ("working", "Working", .okabeBlue),
        ("idle", "Idle", .okabeGray),
        ("failed", "Failed", .okabeVermillion),
        ("done", "Done", .okabeBluishGreen),
    ]
}

// MARK: - Sidebar

struct FleetSidebarContent: View {
    @Environment(SessionStore.self) private var store
    let filterText: String
    let agents: [FleetAgent]
    let queue: [FleetAgent]
    let hooksInstalled: Bool
    @Binding var selection: String?

    @State private var hiddenStates: Set<String> = []
    @State private var bypassOnly = false

    private var visibleAgents: [FleetAgent] {
        agents.filter { agent in
            if hiddenStates.contains(agent.state.filterKey) { return false }
            if bypassOnly && !agent.isBypass { return false }
            if !filterText.isEmpty {
                let haystack = [agent.summary.title, agent.projectName, agent.branchLabel ?? ""]
                    .joined(separator: " ")
                return haystack.localizedCaseInsensitiveContains(filterText)
            }
            return true
        }
    }

    private var groupedByProject: [(project: String, agents: [FleetAgent])] {
        var order: [String] = []
        var groups: [String: [FleetAgent]] = [:]
        for agent in visibleAgents {
            let key = agent.projectName
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(agent)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    private func count(for key: String) -> Int {
        agents.filter { $0.state.filterKey == key }.count
    }

    var body: some View {
        if agents.isEmpty {
            SidebarEmptyStateView(icon: "square.grid.2x2", text: "No agents in the last 24 hours")
        } else {
            LazyVStack(alignment: .leading, spacing: 2) {
                if !hooksInstalled {
                    hooksBanner
                }

                filterPills

                if !queue.isEmpty {
                    sectionHeader("NEEDS YOU · \(queue.count)")
                    ForEach(queue) { agent in
                        FleetAgentRow(agent: agent, showReason: true,
                                      isSelected: selection == agent.id) { selection = agent.id }
                    }
                }

                ForEach(groupedByProject, id: \.project) { group in
                    sectionHeader(group.project.uppercased())
                    ForEach(group.agents) { agent in
                        FleetAgentRow(agent: agent, showReason: false,
                                      isSelected: selection == agent.id) { selection = agent.id }
                    }
                }
            }
            .padding(.bottom, 8)
        }
    }

    private var hooksBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "bell.slash")
                    .foregroundStyle(Color.okabeOrange)
                Text("Permission waits need the notification hooks.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Enable in Settings") {
                store.requestedRail = .settings
            }
            .font(.system(size: 11))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.okabeOrange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    private var filterPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(FleetStateStyle.filterOrder, id: \.key) { item in
                    let n = count(for: item.key)
                    if n > 0 {
                        FilterPill(label: item.label, count: n, color: item.color,
                                   isActive: !hiddenStates.contains(item.key)) {
                            if hiddenStates.contains(item.key) {
                                hiddenStates.remove(item.key)
                            } else {
                                hiddenStates.insert(item.key)
                            }
                        }
                    }
                }
                let bypassCount = agents.filter(\.isBypass).count
                if bypassCount > 0 {
                    Button {
                        bypassOnly.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.shield.fill")
                                .font(.system(size: 9))
                            Text("\(bypassCount)")
                                .font(.system(size: 11, weight: bypassOnly ? .semibold : .regular, design: .monospaced))
                        }
                        .foregroundStyle(Color.okabeVermillion)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(bypassOnly ? Color.okabeVermillion.opacity(0.1) : Color.clear)
                        .clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(
                            bypassOnly ? Color.okabeVermillion.opacity(0.4) : Color.secondary.opacity(0.2), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help(bypassOnly ? "Show all agents" : "Only agents that skipped permissions")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }
}

private struct FleetAgentRow: View {
    let agent: FleetAgent
    let showReason: Bool
    let isSelected: Bool
    let onSelect: () -> Void

    private var subtitle: String {
        if showReason, case .waitingOnUser(let reason) = agent.state { return reason }
        if showReason, agent.state == .blockedOnPermission { return "Permission prompt" }
        var parts: [String] = [agent.state.label]
        if let branch = agent.branchLabel { parts.append(branch) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Circle()
                    .fill(FleetStateStyle.color(agent.state))
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(agent.summary.title)
                            .font(Typography.body)
                            .lineLimit(1)
                            .foregroundStyle(isSelected ? .white : .primary)
                        if agent.isBypass {
                            Image(systemName: "exclamationmark.shield.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(isSelected ? .white : Color.okabeVermillion)
                                .help("Ran with skipped permissions")
                        }
                        if agent.isBackgroundJob {
                            Image(systemName: "rectangle.stack.badge.play")
                                .font(.system(size: 9))
                                .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                                .help("Background job")
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(agent.since, format: .relative(presentation: .named))
                        .font(.system(size: 10))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.tertiary))
                    Text(formatCost(agent.summary.estimatedCost))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(isSelected ? .white.opacity(0.8) : .orange)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Main panel

struct FleetMainPanelView: View {
    @Environment(SessionStore.self) private var store
    let selection: String?
    var onNavigateToSession: ((String, String, String?) -> Void)?

    var body: some View {
        if let id = selection, let agent = store.fleetAgents.first(where: { $0.id == id }) {
            FleetAgentDetailView(agent: agent, onNavigateToSession: onNavigateToSession)
        } else if store.fleetAgents.isEmpty {
            EmptyStateView(
                icon: "square.grid.2x2",
                title: "Fleet",
                message: "Running Claude Code sessions and anything from the last 24 hours show up here."
            )
        } else {
            FleetOverviewView(agents: store.fleetAgents, queue: store.attentionQueue)
        }
    }
}

private struct FleetOverviewView: View {
    let agents: [FleetAgent]
    let queue: [FleetAgent]

    private func count(_ key: String) -> Int { agents.filter { $0.state.filterKey == key }.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Fleet")
                    .font(Typography.panelTitle)

                HStack(spacing: 12) {
                    StatCard(title: "Live", value: "\(agents.filter(\.isLive).count)")
                    StatCard(title: "Working", value: "\(count("working"))")
                    StatCard(title: "Waiting", value: "\(count("waiting") + count("blocked"))",
                             isHighlighted: count("waiting") + count("blocked") > 0)
                    StatCard(title: "Skipped permissions", value: "\(agents.filter { $0.isBypass && $0.isLive }.count)",
                             isHighlighted: agents.contains { $0.isBypass && $0.isLive })
                }

                if !queue.isEmpty {
                    CardView {
                        VStack(alignment: .leading, spacing: 8) {
                            ConfigSectionHeader(title: "NEEDS YOU")
                            ForEach(queue) { agent in
                                HStack(spacing: 8) {
                                    Circle().fill(FleetStateStyle.color(agent.state)).frame(width: 8, height: 8)
                                    Text(agent.summary.title).font(Typography.body).lineLimit(1)
                                    Text(agent.projectName).font(.system(size: 11)).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(agent.since, format: .relative(presentation: .named))
                                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }

                Text("Select an agent in the sidebar for details, or press the jump shortcut to focus the oldest waiting terminal.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }
}

private struct FleetAgentDetailView: View {
    let agent: FleetAgent
    var onNavigateToSession: ((String, String, String?) -> Void)?

    private var summary: SessionSummary { agent.summary }

    private var elapsed: String {
        let start = agent.registry?.startedDate ?? ISO8601.parse(summary.firstTimestamp) ?? agent.since
        let end = agent.isLive ? Date() : (ISO8601.parse(summary.lastTimestamp) ?? Date())
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return String(format: "%dh %02dm", seconds / 3600, (seconds % 3600) / 60)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(FleetStateStyle.color(agent.state))
                    .frame(width: 10, height: 10)
                Text(summary.title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                Text(agent.state.label)
                    .font(Typography.micro)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(AnyShapeStyle(.quaternary))
                    .clipShape(Capsule())
                    .foregroundStyle(.secondary)
                if agent.isBypass {
                    Label("Skipped permissions", systemImage: "exclamationmark.shield.fill")
                        .font(Typography.micro)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.okabeVermillion.opacity(0.12))
                        .foregroundStyle(Color.okabeVermillion)
                        .clipShape(Capsule())
                }
                Spacer()
                if !summary.isCowork {
                    Button("Focus terminal") {
                        TerminalFocuser.focus(matchingTitle: agent.focusNeedle)
                    }
                    .font(.system(size: 11))
                    .disabled(!agent.isLive)
                    .help(agent.isLive ? "Bring the terminal tab titled \(agent.focusNeedle) forward" : "The process is no longer running")
                }
                Button("Open session") {
                    onNavigateToSession?(summary.projectId, summary.id, nil)
                }
                .font(.system(size: 11))
                .disabled(summary.isCowork)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.bar)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if case .waitingOnUser(let reason) = agent.state {
                        attentionCard(reason)
                    } else if agent.state == .blockedOnPermission {
                        attentionCard("Waiting for a permission decision.")
                    }

                    CardView {
                        VStack(alignment: .leading, spacing: 8) {
                            ConfigSectionHeader(title: "AGENT")
                            detailRow("Project", agent.projectName)
                            detailRow("Branch", agent.branchLabel)
                            detailRow("Worktree", summary.worktreeName)
                            if let pr = summary.prNumber { detailRow("Pull request", "#\(pr)") }
                            detailRow("Model", summary.primaryModel.map { getModelFamily($0) })
                            detailRow("Permission mode", summary.lastPermissionMode)
                            detailRow("Elapsed", elapsed)
                            detailRow("Last activity", formatRelativeTime(summary.lastTimestamp))
                            detailRow("Tokens", formatTokens(summary.totalInputTokens + summary.totalOutputTokens))
                            detailRow("Estimated cost", formatCost(summary.estimatedCost))
                            if agent.isBackgroundJob { detailRow("Kind", "Background job") }
                        }
                    }

                    if let reg = agent.registry {
                        CardView {
                            VStack(alignment: .leading, spacing: 8) {
                                ConfigSectionHeader(title: "PROCESS")
                                detailRow("pid", "\(reg.pid)")
                                detailRow("Status", reg.status)
                                detailRow("Kind", reg.kind)
                                detailRow("Claude Code", reg.version)
                                detailRow("Working directory", reg.cwd)
                                detailRow("Job", reg.jobId)
                            }
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 760, alignment: .leading)
            }
        }
    }

    private func attentionCard(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(FleetStateStyle.color(agent.state))
            Text(text)
                .font(Typography.body)
            Spacer()
            Text("since \(agent.since, format: .relative(presentation: .named))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FleetStateStyle.color(agent.state).opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
    }

    @ViewBuilder
    private func detailRow(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top, spacing: 12) {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 130, alignment: .leading)
                Text(value)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }
}
