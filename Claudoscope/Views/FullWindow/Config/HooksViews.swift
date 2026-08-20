import SwiftUI

// MARK: - Hooks

struct HooksSidebarContent: View {
    let filterText: String
    let hookGroups: [HookEventGroup]
    var runtimeAggregates: [HookRuntimeAggregate] = []
    @Binding var selectedEventId: String?

    private var filtered: [HookEventGroup] {
        if filterText.isEmpty { return hookGroups }
        return hookGroups.filter { group in
            group.event.localizedCaseInsensitiveContains(filterText) ||
            group.rules.contains { $0.matcher.localizedCaseInsensitiveContains(filterText) }
        }
    }

    /// (fires, errors) per event, summed from aggregates whose hookName is the
    /// event itself ("Stop") or event-prefixed ("PreToolUse:Bash").
    private func runtimeCounts(for event: String) -> (fires: Int, errors: Int) {
        var fires = 0
        var errors = 0
        for agg in runtimeAggregates where agg.hookName == event || agg.hookName.hasPrefix(event + ":") {
            fires += agg.fireCount
            errors += agg.errorCount
        }
        return (fires, errors)
    }

    var body: some View {
        if filtered.isEmpty {
            SidebarEmptyStateView(icon: "arrow.triangle.turn.up.right.diamond", text: "No hooks configured")
        } else {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(filtered) { group in
                    HookEventRow(
                        group: group,
                        runtimeCounts: runtimeCounts(for: group.event),
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
    var runtimeCounts: (fires: Int, errors: Int) = (0, 0)
    let isSelected: Bool
    let onSelect: () -> Void

    private var subtitle: String {
        var text = "\(group.rules.count) rule\(group.rules.count == 1 ? "" : "s")"
        if runtimeCounts.fires > 0 {
            text += " · \(runtimeCounts.fires) fired"
            if runtimeCounts.errors > 0 {
                text += ", \(runtimeCounts.errors) failed"
            }
        }
        return text
    }

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

                    Text(subtitle)
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
        case "PermissionDenied": return "hand.raised.slash"
        case "SessionStart": return "play.circle"
        case "Stop": return "stop.circle"
        case "UserPromptSubmit": return "paperplane"
        case "Notification": return "bell"
        case "SessionEnd": return "flag.checkered"
        case "SubagentStop": return "stop.circle.fill"
        case "PreCompact": return "arrow.down.right.and.arrow.up.left"
        case "PostToolUseFailure": return "exclamationmark.triangle"
        case "FileChanged": return "doc.badge.ellipsis"
        default: return "gearshape"
        }
    }
}

struct HooksMainPanelView: View {
    static let eventsWithDurationMs: Set<String> = ["PostToolUse", "PostToolUseFailure"]

    let hookGroups: [HookEventGroup]
    var runtimeAggregates: [HookRuntimeAggregate] = []
    let selectedEventId: String?

    private enum Dimension: String, CaseIterable {
        case configuration = "Configuration"
        case runtime = "Runtime"
    }
    @State private var dimension: Dimension = .configuration

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $dimension) {
                ForEach(Dimension.allCases, id: \.self) { dim in
                    Text(dim.rawValue).tag(dim)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 280)
            .padding(.vertical, 8)

            Divider()

            switch dimension {
            case .configuration:
                configurationContent
            case .runtime:
                HooksRuntimePanel(aggregates: runtimeAggregates)
            }
        }
    }

    @ViewBuilder
    private var configurationContent: some View {
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

                Link(destination: URL(string: "https://docs.claude.com/en/docs/claude-code/hooks")!) {
                    HStack(spacing: 3) {
                        Text("Hook reference")
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 10))
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }

                Text("\(group.rules.count) rule\(group.rules.count == 1 ? "" : "s")")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.bar)

            if Self.eventsWithDurationMs.contains(group.event) {
                HStack(spacing: 6) {
                    Image(systemName: "stopwatch")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("Hook stdin includes duration_ms (Claude Code 2.1.119+).")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 6)
                .background(.bar.opacity(0.5))
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(group.rules) { rule in
                        CardView {
                            VStack(alignment: .leading, spacing: 10) {
                                // Source
                                HStack(spacing: 6) {
                                    ConfigSectionHeader(title: "SOURCE")
                                    Spacer()
                                    Text(rule.source.label)
                                        .font(Typography.micro)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(AnyShapeStyle(.quaternary))
                                        .clipShape(Capsule())
                                        .foregroundStyle(.secondary)
                                }

                                Divider()

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

                                            if let seq = hook.terminalSequence {
                                                Text("terminalSequence: \(seq)")
                                                    .font(.system(size: 11, design: .monospaced))
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

// MARK: - Runtime Panel

/// Cross-session hook runtime: what actually fired across all parsed sessions,
/// folded from SessionSummary.hookRunStats by HookRuntimeEngine.
private struct HooksRuntimePanel: View {
    let aggregates: [HookRuntimeAggregate]

    private var totalFailures: Int {
        aggregates.reduce(0) { $0 + $1.errorCount }
    }

    var body: some View {
        if aggregates.isEmpty {
            EmptyStateView(
                icon: "arrow.triangle.turn.up.right.diamond",
                title: "No hook activity yet",
                message: "Runtime stats appear after sessions that ran hooks are parsed. Recent Claude Code versions record hook execution in the transcript."
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 16) {
                        runtimeStat(label: "Hooks", value: "\(aggregates.count)")
                        runtimeStat(label: "Total fires", value: "\(aggregates.reduce(0) { $0 + $1.fireCount })")
                        runtimeStat(label: "Failures", value: "\(totalFailures)", highlight: totalFailures > 0)
                    }

                    ForEach(aggregates) { agg in
                        CardView {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    Text(agg.hookName)
                                        .font(.system(size: 13, weight: .medium))
                                    if !agg.isConfigured {
                                        Text("not in config")
                                            .font(Typography.micro)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.okabeOrange.opacity(0.15))
                                            .clipShape(Capsule())
                                            .foregroundStyle(Color.okabeOrange)
                                            .help("This command appears in transcripts but matches no currently configured hook")
                                    }
                                    Spacer()
                                    if agg.errorCount > 0 {
                                        Text("\(agg.errorCount) failed")
                                            .font(.system(size: 11))
                                            .foregroundStyle(Color.okabeVermillion)
                                    }
                                }

                                Text(agg.command.isEmpty ? "(no command recorded)" : agg.command)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .textSelection(.enabled)

                                HStack(spacing: 12) {
                                    Text("\(agg.fireCount) fire\(agg.fireCount == 1 ? "" : "s")")
                                    Text("\(agg.sessionCount) session\(agg.sessionCount == 1 ? "" : "s")")
                                    if agg.avgDurationMs > 0 {
                                        Text("avg \(agg.avgDurationMs)ms")
                                    }
                                    if agg.maxDurationMs > 0 {
                                        Text("max \(agg.maxDurationMs)ms")
                                    }
                                }
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func runtimeStat(label: String, value: String, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(highlight ? Color.okabeVermillion : Color.primary)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 80, alignment: .leading)
    }
}
