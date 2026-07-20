import SwiftUI

// MARK: - Routing Badge

/// Marks the core routing roles from the user's agent-routing convention
/// (recon, Explore, routine, builder, checker, security-review, security-build).
struct RoutingBadge: View {
    var isSelected: Bool = false

    var body: some View {
        Text("Claudoscope routing")
            .font(Typography.micro)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isSelected ? AnyShapeStyle(.white.opacity(0.2)) : AnyShapeStyle(Color.accentColor.opacity(0.15)))
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(Color.accentColor))
            .clipShape(Capsule())
    }
}

// MARK: - Agents Sidebar

struct AgentsSidebarContent: View {
    let filterText: String
    let agents: [AgentEntry]
    @Binding var selectedAgentName: String?

    private var filtered: [AgentEntry] {
        if filterText.isEmpty { return agents }
        return agents.filter { agent in
            agent.name.localizedCaseInsensitiveContains(filterText) ||
            agent.displayName.localizedCaseInsensitiveContains(filterText) ||
            (agent.description?.localizedCaseInsensitiveContains(filterText) ?? false)
        }
    }

    private var routing: [AgentEntry] { filtered.filter { $0.isRoutingAgent } }
    private var others: [AgentEntry] { filtered.filter { !$0.isRoutingAgent } }

    var body: some View {
        if filtered.isEmpty {
            SidebarEmptyStateView(icon: "person.2", text: "No agents found")
        } else {
            LazyVStack(alignment: .leading, spacing: 2) {
                if !routing.isEmpty {
                    sectionHeader("CLAUDOSCOPE ROUTING")
                    ForEach(routing) { agent in row(agent) }
                }
                if !others.isEmpty {
                    sectionHeader("AGENTS")
                    ForEach(others) { agent in row(agent) }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(Typography.caption)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    private func row(_ agent: AgentEntry) -> some View {
        AgentRow(agent: agent, isSelected: selectedAgentName == agent.displayName) {
            selectedAgentName = agent.displayName
        }
    }
}

struct AgentRow: View {
    let agent: AgentEntry
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(agent.name)
                        .font(Typography.bodyMedium)
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? .white : .primary)

                    Spacer(minLength: 4)

                    if agent.isRoutingAgent {
                        RoutingBadge(isSelected: isSelected)
                    }
                }

                HStack(spacing: 4) {
                    Text(agent.description ?? agent.source.label)
                        .font(.system(size: 11))
                        .lineLimit(1)

                    Spacer()

                    Text(formatFileSize(agent.sizeBytes))
                        .font(.system(size: 11))
                }
                .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
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

// MARK: - Agents Main Panel

struct AgentsMainPanelView: View {
    let agents: [AgentEntry]
    @Binding var selectedAgentName: String?

    private static let agentKnownKeys: [(key: String, label: String, icon: String)] = [
        ("model", "Model", "cpu"),
        ("effort", "Effort", "speedometer"),
        ("maxTurns", "Max Turns", "arrow.triangle.2.circlepath"),
        ("skills", "Skills", "star"),
    ]

    private var selectedAgent: AgentEntry? {
        guard let name = selectedAgentName else { return nil }
        return agents.first { $0.displayName == name }
    }

    var body: some View {
        if let agent = selectedAgent {
            agentDetailContent(agent)
        } else if agents.isEmpty {
            EmptyStateView(
                icon: "person.2",
                title: "No agents found",
                message: "Agents are .md files in ~/.claude/agents/, a project's .claude/agents/, or plugins."
            )
        } else {
            EmptyStateView(
                icon: "person.2",
                title: "Select an agent",
                message: "Choose an agent from the sidebar to view its definition."
            )
        }
    }

    @ViewBuilder
    private func agentDetailContent(_ agent: AgentEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Button {
                    selectedAgentName = nil
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Text(agent.name)
                    .font(.system(size: 14, weight: .medium))

                if agent.isRoutingAgent {
                    RoutingBadge()
                }

                Spacer()

                Text(agent.source.label)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text(formatFileSize(agent.sizeBytes))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.bar)

            Divider()

            // Description banner
            if let desc = agent.description {
                HStack(spacing: 6) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Text(desc)
                        .font(Typography.body)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .background(.bar.opacity(0.5))

                Divider()
            }

            // Body content
            ScrollView {
                if agent.body.isEmpty && agent.metadata.isEmpty {
                    EmptyStateView(
                        icon: "doc.text",
                        title: "No content",
                        message: "This agent has no body content beyond its metadata."
                    )
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        if agent.metadata["tools"] != nil || agent.metadata["disallowed-tools"] != nil {
                            SkillToolRestrictionsView(
                                allowedTools: agent.metadata["tools"],
                                disallowedTools: agent.metadata["disallowed-tools"]
                            )
                        }

                        let filteredMetadata = agent.metadata.filter {
                            $0.key != "tools" && $0.key != "disallowed-tools"
                        }
                        if !filteredMetadata.isEmpty {
                            SkillMetadataCard(metadata: filteredMetadata, knownKeys: Self.agentKnownKeys)
                        }

                        if !agent.body.isEmpty {
                            RichMarkdownContentView(content: agent.body)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
