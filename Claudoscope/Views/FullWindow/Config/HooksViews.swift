import SwiftUI

// MARK: - Hooks

struct HooksSidebarContent: View {
    let filterText: String
    let hookGroups: [HookEventGroup]
    @Binding var selectedEventId: String?

    private var filtered: [HookEventGroup] {
        if filterText.isEmpty { return hookGroups }
        return hookGroups.filter { group in
            group.event.localizedCaseInsensitiveContains(filterText) ||
            group.rules.contains { $0.matcher.localizedCaseInsensitiveContains(filterText) }
        }
    }

    var body: some View {
        if filtered.isEmpty {
            SidebarEmptyStateView(icon: "arrow.triangle.turn.up.right.diamond", text: "No hooks configured")
        } else {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(filtered) { group in
                    HookEventRow(
                        group: group,
                        isSelected: selectedEventId == group.id
                    ) {
                        selectedEventId = group.id
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct HookEventRow: View {
    let group: HookEventGroup
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: iconForEvent(group.event))
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? .white : .secondary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(group.event)
                        .font(Typography.body)
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? .white : .primary)

                    Text("\(group.rules.count) rule\(group.rules.count == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
                }

                Spacer()

                Text("\(group.rules.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.tertiary))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(isSelected ? AnyShapeStyle(.white.opacity(0.2)) : AnyShapeStyle(.quaternary))
                    .clipShape(Capsule())
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

    private func iconForEvent(_ event: String) -> String {
        switch event {
        case "PreToolUse": return "arrow.right.to.line"
        case "PostToolUse": return "arrow.left.to.line"
        case "SessionStart": return "play.circle"
        case "Stop": return "stop.circle"
        case "UserPromptSubmit": return "paperplane"
        case "Notification": return "bell"
        default: return "gearshape"
        }
    }
}

struct HooksMainPanelView: View {
    let hookGroups: [HookEventGroup]
    let selectedEventId: String?

    var body: some View {
        if let eventId = selectedEventId,
           let group = hookGroups.first(where: { $0.id == eventId }) {
            hookDetailContent(group)
        } else if hookGroups.isEmpty {
            EmptyStateView(
                icon: "arrow.triangle.turn.up.right.diamond",
                title: "No hooks configured",
                message: "Hooks are defined in ~/.claude/settings.json under the \"hooks\" key."
            )
        } else {
            EmptyStateView(
                icon: "arrow.triangle.turn.up.right.diamond",
                title: "Select an event",
                message: "Choose a hook event from the sidebar to view its rules."
            )
        }
    }

    @ViewBuilder
    private func hookDetailContent(_ group: HookEventGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Text(group.event)
                    .font(.system(size: 14, weight: .medium))

                Spacer()

                Text("\(group.rules.count) rule\(group.rules.count == 1 ? "" : "s")")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.bar)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(group.rules) { rule in
                        CardView {
                            VStack(alignment: .leading, spacing: 10) {
                                // Matcher
                                HStack(spacing: 6) {
                                    ConfigSectionHeader(title: "MATCHER")
                                    Spacer()
                                    Text(rule.matcher)
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundStyle(.primary)
                                }

                                Divider()

                                // Commands
                                ConfigSectionHeader(title: "COMMANDS")

                                ForEach(Array(rule.hooks.enumerated()), id: \.offset) { _, hook in
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: "terminal")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.tertiary)
                                            .frame(width: 14, alignment: .center)
                                            .padding(.top, 2)

                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(hook.command)
                                                .font(.system(size: 13, design: .monospaced))
                                                .textSelection(.enabled)

                                            if let timeout = hook.timeout {
                                                Text("timeout: \(timeout)ms")
                                                    .font(.system(size: 11))
                                                    .foregroundStyle(.tertiary)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
