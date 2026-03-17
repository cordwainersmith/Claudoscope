import SwiftUI

// MARK: - Shared Helpers

/// Mask an environment variable value, showing only first 2 and last 2 characters.
private func maskEnvValue(_ value: String) -> String {
    guard value.count > 6 else { return "***" }
    let prefix = value.prefix(2)
    let suffix = value.suffix(2)
    return "\(prefix)***\(suffix)"
}

/// Section header styled consistently.
private struct ConfigSectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.tertiary)
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Hooks
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

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

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Commands / Skills
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct CommandsSidebarContent: View {
    let filterText: String
    let commands: [CommandEntry]
    @Binding var selectedCommandName: String?

    private var filtered: [CommandEntry] {
        if filterText.isEmpty { return commands }
        return commands.filter { cmd in
            cmd.name.localizedCaseInsensitiveContains(filterText) ||
            (cmd.description?.localizedCaseInsensitiveContains(filterText) ?? false)
        }
    }

    var body: some View {
        if filtered.isEmpty {
            SidebarEmptyStateView(icon: "terminal", text: "No commands found")
        } else {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(filtered) { cmd in
                    CommandRow(
                        command: cmd,
                        isSelected: selectedCommandName == cmd.name
                    ) {
                        selectedCommandName = cmd.name
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct CommandRow: View {
    let command: CommandEntry
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 2) {
                Text("/\(command.name)")
                    .font(Typography.bodyMedium)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? .white : .primary)

                HStack(spacing: 4) {
                    if let desc = command.description {
                        Text(desc)
                            .font(.system(size: 11))
                            .lineLimit(1)
                    }

                    Spacer()

                    Text(formatFileSize(command.sizeBytes))
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

struct CommandsMainPanelView: View {
    let commands: [CommandEntry]
    @Binding var selectedCommandName: String?

    private var selectedCommand: CommandEntry? {
        guard let name = selectedCommandName else { return nil }
        return commands.first { $0.name == name }
    }

    var body: some View {
        if let command = selectedCommand {
            commandDetailContent(command)
        } else if commands.isEmpty {
            EmptyStateView(
                icon: "terminal",
                title: "No commands found",
                message: "Custom slash commands are .md files in ~/.claude/commands/"
            )
        } else {
            EmptyStateView(
                icon: "terminal",
                title: "Select a command",
                message: "Choose a command from the sidebar to view its contents."
            )
        }
    }

    @ViewBuilder
    private func commandDetailContent(_ command: CommandEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Button {
                    selectedCommandName = nil
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Text("/\(command.name)")
                    .font(.system(size: 14, weight: .medium))

                Spacer()

                Text(formatFileSize(command.sizeBytes))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.bar)

            Divider()

            if let desc = command.description {
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

            // Content
            ScrollView {
                RichMarkdownContentView(content: command.content)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Skills

struct SkillsSidebarContent: View {
    let filterText: String
    let skills: [SkillEntry]
    @Binding var selectedSkillName: String?

    private var filtered: [SkillEntry] {
        if filterText.isEmpty { return skills }
        return skills.filter { skill in
            skill.name.localizedCaseInsensitiveContains(filterText) ||
            skill.displayName.localizedCaseInsensitiveContains(filterText) ||
            (skill.description?.localizedCaseInsensitiveContains(filterText) ?? false)
        }
    }

    var body: some View {
        if filtered.isEmpty {
            SidebarEmptyStateView(icon: "star", text: "No skills found")
        } else {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(filtered) { skill in
                    SkillRow(
                        skill: skill,
                        isSelected: selectedSkillName == skill.displayName
                    ) {
                        selectedSkillName = skill.displayName
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct SkillRow: View {
    let skill: SkillEntry
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 2) {
                Text("/\(skill.name)")
                    .font(Typography.bodyMedium)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? .white : .primary)

                HStack(spacing: 4) {
                    if let desc = skill.description {
                        Text(desc)
                            .font(.system(size: 11))
                            .lineLimit(1)
                    } else {
                        Text("name: \(skill.name)")
                            .font(.system(size: 11))
                            .lineLimit(1)
                    }

                    Spacer()

                    Text(formatFileSize(skill.sizeBytes))
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

struct SkillsMainPanelView: View {
    let skills: [SkillEntry]
    @Binding var selectedSkillName: String?

    private var selectedSkill: SkillEntry? {
        guard let name = selectedSkillName else { return nil }
        return skills.first { $0.displayName == name }
    }

    var body: some View {
        if let skill = selectedSkill {
            skillDetailContent(skill)
        } else if skills.isEmpty {
            EmptyStateView(
                icon: "star",
                title: "No skills found",
                message: "Skills are SKILL.md files in ~/.claude/skills/ or installed via plugins."
            )
        } else {
            EmptyStateView(
                icon: "star",
                title: "Select a skill",
                message: "Choose a skill from the sidebar to view its contents."
            )
        }
    }

    @ViewBuilder
    private func skillDetailContent(_ skill: SkillEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Button {
                    selectedSkillName = nil
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Text("/\(skill.name)")
                    .font(.system(size: 14, weight: .medium))

                Spacer()

                Text(formatFileSize(skill.sizeBytes))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.bar)

            Divider()

            // Description banner
            if let desc = skill.description {
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
                if skill.body.isEmpty && skill.metadata.isEmpty {
                    EmptyStateView(
                        icon: "doc.text",
                        title: "No content",
                        message: "This skill has no body content beyond its metadata."
                    )
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        // Metadata card
                        if !skill.metadata.isEmpty {
                            SkillMetadataCard(metadata: skill.metadata)
                        }

                        if !skill.body.isEmpty {
                            RichMarkdownContentView(content: skill.body)
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

// MARK: - Skill Metadata Card

private struct SkillMetadataCard: View {
    let metadata: [String: String]

    // Keys to display with nice labels and icons
    private static let knownKeys: [(key: String, label: String, icon: String)] = [
        ("author", "Author", "person"),
        ("version", "Version", "tag"),
        ("mcp-server", "MCP Server", "point.3.connected.trianglepath.dotted"),
        ("user-invokable", "User Invokable", "person.crop.circle.badge.checkmark"),
        ("args", "Arguments", "list.bullet.rectangle"),
    ]

    private var sortedEntries: [(label: String, icon: String, value: String)] {
        var entries: [(label: String, icon: String, value: String)] = []
        var seen: Set<String> = []

        // Known keys first, in order
        for known in Self.knownKeys {
            if let value = metadata[known.key] {
                entries.append((known.label, known.icon, value))
                seen.insert(known.key)
            }
        }

        // Remaining keys
        for key in metadata.keys.sorted() where !seen.contains(key) {
            entries.append((key.capitalized, "info.circle", metadata[key]!))
        }

        return entries
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("Metadata")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Divider().padding(.horizontal, 14)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(sortedEntries.enumerated()), id: \.offset) { idx, entry in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: entry.icon)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .frame(width: 14, alignment: .center)
                            .padding(.top, 2)

                        Text(entry.label)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 100, alignment: .leading)

                        Text(entry.value)
                            .font(Typography.code)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)

                    if idx < sortedEntries.count - 1 {
                        Divider().opacity(0.4).padding(.horizontal, 14)
                    }
                }
            }
            .padding(.bottom, 6)
        }
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - MCPs
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct McpsSidebarContent: View {
    let filterText: String
    let mcpServers: [McpServerEntry]
    @Binding var selectedMcpName: String?

    private var filtered: [McpServerEntry] {
        if filterText.isEmpty { return mcpServers }
        return mcpServers.filter { server in
            server.name.localizedCaseInsensitiveContains(filterText) ||
            (server.command?.localizedCaseInsensitiveContains(filterText) ?? false) ||
            (server.url?.localizedCaseInsensitiveContains(filterText) ?? false)
        }
    }

    var body: some View {
        if filtered.isEmpty {
            SidebarEmptyStateView(icon: "point.3.connected.trianglepath.dotted", text: "No MCP servers found")
        } else {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(filtered) { server in
                    McpServerRow(
                        server: server,
                        isSelected: selectedMcpName == server.name
                    ) {
                        selectedMcpName = server.name
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct McpServerRow: View {
    let server: McpServerEntry
    let isSelected: Bool
    let onSelect: () -> Void

    private var serverType: String {
        if server.url != nil { return "http" }
        return "stdio"
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                // Status dot
                Circle()
                    .fill(isSelected ? .white : .secondary)
                    .frame(width: 6, height: 6)
                    .help("Configured in settings.json")

                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                        .font(Typography.body)
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? .white : .primary)

                    Text(serverType)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
                }

                Spacer()

                if let level = server.level {
                    Text(level)
                        .font(Typography.micro)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(isSelected ? AnyShapeStyle(.white.opacity(0.2)) : AnyShapeStyle(.quaternary))
                        .clipShape(Capsule())
                        .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
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

struct McpsMainPanelView: View {
    let mcpServers: [McpServerEntry]
    let selectedMcpName: String?

    @State private var expandedServer: String?

    var body: some View {
        if mcpServers.isEmpty {
            EmptyStateView(
                icon: "point.3.connected.trianglepath.dotted",
                title: "No MCP servers",
                message: "MCP servers are defined in ~/.claude/settings.json under the \"mcpServers\" key."
            )
        } else {
            ScrollView {
                let columns = [
                    GridItem(.adaptive(minimum: 280, maximum: 400), spacing: 12)
                ]

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(mcpServers) { server in
                        McpServerCard(
                            server: server,
                            isExpanded: expandedServer == server.name
                        ) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                expandedServer = expandedServer == server.name ? nil : server.name
                            }
                        }
                    }
                }
                .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct McpServerCard: View {
    let server: McpServerEntry
    let isExpanded: Bool
    let onToggle: () -> Void

    private var serverType: String {
        if server.url != nil { return "HTTP" }
        return "stdio"
    }

    private var connectionString: String {
        if let url = server.url { return url }
        if let command = server.command {
            if server.args.isEmpty { return command }
            return command + " " + server.args.joined(separator: " ")
        }
        return ""
    }

    var body: some View {
        Button(action: onToggle) {
            VStack(alignment: .leading, spacing: 0) {
                // Card header
                HStack(spacing: 10) {
                    // Icon area
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(server.url != nil ? Color.blue.opacity(0.12) : Color.green.opacity(0.12))
                            .frame(width: 36, height: 36)

                        Image(systemName: server.url != nil ? "globe" : "terminal")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(server.url != nil ? .blue : .green)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(server.name)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)

                        HStack(spacing: 6) {
                            Text(serverType)
                                .font(Typography.caption)
                                .foregroundStyle(server.url != nil ? .blue : .green)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background((server.url != nil ? Color.blue : Color.green).opacity(0.1))
                                .clipShape(Capsule())

                            if let level = server.level {
                                Text(level)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }

                    Spacer()

                    Image(systemName: "chevron.down")
                        .font(Typography.caption)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(isExpanded ? .degrees(180) : .zero)
                }
                .padding(14)

                // Connection preview (always visible)
                if !connectionString.isEmpty {
                    Divider().padding(.horizontal, 14)

                    Text(connectionString)
                        .font(Typography.code)
                        .foregroundStyle(.secondary)
                        .lineLimit(isExpanded ? nil : 1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }

                // Expanded details
                if isExpanded {
                    Divider().padding(.horizontal, 14)

                    VStack(alignment: .leading, spacing: 10) {
                        if !server.args.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("ARGUMENTS")
                                    .font(Typography.caption)
                                    .foregroundStyle(.tertiary)

                                ForEach(Array(server.args.enumerated()), id: \.offset) { index, arg in
                                    HStack(spacing: 6) {
                                        Text("\(index)")
                                            .font(Typography.codeSmall)
                                            .foregroundStyle(.tertiary)
                                            .frame(width: 16, alignment: .trailing)
                                        Text(arg)
                                            .font(Typography.code)
                                            .textSelection(.enabled)
                                            .lineLimit(2)
                                    }
                                }
                            }
                        }

                        if !server.env.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("ENVIRONMENT")
                                    .font(Typography.caption)
                                    .foregroundStyle(.tertiary)

                                ForEach(server.env.keys.sorted(), id: \.self) { key in
                                    HStack(spacing: 6) {
                                        Text(key)
                                            .font(Typography.code)
                                            .lineLimit(1)
                                        Spacer()
                                        Text(maskEnvValue(server.env[key] ?? ""))
                                            .font(Typography.code)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
        }
        .buttonStyle(.plain)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Memory
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct MemorySidebarContent: View {
    let filterText: String
    let projects: [Project]
    let memoryFiles: [MemoryFile]
    @Binding var selectedMemoryId: String?
    @Binding var selectedProjectId: String?

    private var filteredProjects: [Project] {
        if filterText.isEmpty { return projects }
        return projects.filter { $0.name.localizedCaseInsensitiveContains(filterText) }
    }

    private var showGlobal: Bool {
        filterText.isEmpty || "global".localizedCaseInsensitiveContains(filterText)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            // Global entry
            if showGlobal {
                MemoryProjectRow(
                    name: "Global",
                    icon: "globe",
                    fileCount: 1,
                    isSelected: selectedProjectId == nil
                ) {
                    selectedProjectId = nil
                    selectedMemoryId = nil
                }
            }

            // Per-project entries
            ForEach(filteredProjects) { project in
                MemoryProjectRow(
                    name: project.name,
                    icon: "folder",
                    fileCount: nil,
                    isSelected: selectedProjectId == project.id
                ) {
                    selectedProjectId = project.id
                    selectedMemoryId = nil
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct MemoryProjectRow: View {
    let name: String
    let icon: String
    let fileCount: Int?
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? .white : .secondary)
                    .frame(width: 16)

                Text(name)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? .white : .primary)

                Spacer()

                if let count = fileCount {
                    Text("\(count)")
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.tertiary))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(isSelected ? AnyShapeStyle(.white.opacity(0.2)) : AnyShapeStyle(Color.secondary.opacity(0.15)))
                        .clipShape(Capsule())
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

struct MemoryMainPanelView: View {
    let memoryFiles: [MemoryFile]
    @Binding var selectedMemoryId: String?

    private var selectedFile: MemoryFile? {
        guard let id = selectedMemoryId else { return nil }
        return memoryFiles.first { $0.id == id }
    }

    var body: some View {
        if memoryFiles.isEmpty {
            EmptyStateView(
                icon: "brain",
                title: "Select a scope",
                message: "Choose Global or a project from the sidebar to view memory files."
            )
        } else if let file = selectedFile {
            memoryDetailContent(file)
        } else {
            // Show file list for this scope
            memoryFileList
        }
    }

    private var memoryFileList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(memoryFiles) { file in
                Button {
                    selectedMemoryId = file.id
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(file.content != nil ? Color.green : Color.secondary.opacity(0.3))
                            .frame(width: 6, height: 6)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.label)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.primary)

                            Text(file.sublabel)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if let sizeBytes = file.sizeBytes {
                            Text(formatFileSize(sizeBytes))
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                        } else {
                            Text("missing")
                                .font(.system(size: 12))
                                .foregroundStyle(.quaternary)
                        }

                        Image(systemName: "chevron.right")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Divider().padding(.leading, 24)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func memoryDetailContent(_ file: MemoryFile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with tab-like display
            HStack(spacing: 12) {
                ForEach(memoryFiles) { tab in
                    Button {
                        selectedMemoryId = tab.id
                    } label: {
                        Text(tab.sublabel.capitalized)
                            .font(.system(size: 13, weight: tab.id == file.id ? .medium : .regular))
                            .foregroundStyle(tab.id == file.id ? .primary : .secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(tab.id == file.id ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .opacity(tab.content != nil ? 1.0 : 0.5)
                }

                Spacer()

                Text(file.path)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            // Content
            if let content = file.content {
                ScrollView {
                    MarkdownContentView(content: content, fontSize: 12)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(24)
                }
            } else {
                EmptyStateView(
                    icon: "brain",
                    title: "No memory available",
                    message: "This memory file doesn't exist yet. It will be created when Claude Code writes memory for this scope."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

