import SwiftUI

// MARK: - Shared Helpers

/// Mask an environment variable value, showing only first 2 and last 2 characters.
private func maskEnvValue(_ value: String) -> String {
    guard value.count > 6 else { return "***" }
    let prefix = value.prefix(2)
    let suffix = value.suffix(2)
    return "\(prefix)***\(suffix)"
}

/// Format byte count for display.
private func formatConfigFileSize(_ bytes: Int) -> String {
    if bytes < 1024 {
        return "\(bytes) B"
    } else if bytes < 1024 * 1024 {
        let kb = Double(bytes) / 1024.0
        return String(format: "%.1f KB", kb)
    } else {
        let mb = Double(bytes) / (1024.0 * 1024.0)
        return String(format: "%.1f MB", mb)
    }
}

/// Card container with cardBackground and quaternary border.
private struct ConfigCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.quaternary, lineWidth: 1)
            )
    }
}

/// Section header styled consistently.
private struct ConfigSectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .medium))
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
            ConfigEmptyList(icon: "arrow.triangle.turn.up.right.diamond", text: "No hooks configured")
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
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? .white : .secondary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(group.event)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? .white : .primary)

                    Text("\(group.rules.count) rule\(group.rules.count == 1 ? "" : "s")")
                        .font(.system(size: 10))
                        .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
                }

                Spacer()

                Text("\(group.rules.count)")
                    .font(.system(size: 10))
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
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.bar)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(group.rules) { rule in
                        ConfigCard {
                            VStack(alignment: .leading, spacing: 10) {
                                // Matcher
                                HStack(spacing: 6) {
                                    ConfigSectionHeader(title: "MATCHER")
                                    Spacer()
                                    Text(rule.matcher)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(.primary)
                                }

                                Divider()

                                // Commands
                                ConfigSectionHeader(title: "COMMANDS")

                                ForEach(Array(rule.hooks.enumerated()), id: \.offset) { _, hook in
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: "terminal")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.tertiary)
                                            .frame(width: 14, alignment: .center)
                                            .padding(.top, 2)

                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(hook.command)
                                                .font(.system(size: 12, design: .monospaced))
                                                .textSelection(.enabled)

                                            if let timeout = hook.timeout {
                                                Text("timeout: \(timeout)ms")
                                                    .font(.system(size: 10))
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
            ConfigEmptyList(icon: "terminal", text: "No commands found")
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
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? .white : .primary)

                HStack(spacing: 4) {
                    if let desc = command.description {
                        Text(desc)
                            .font(.system(size: 10))
                            .lineLimit(1)
                    }

                    Spacer()

                    Text(formatConfigFileSize(command.sizeBytes))
                        .font(.system(size: 10))
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
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Text("/\(command.name)")
                    .font(.system(size: 14, weight: .medium))

                Spacer()

                Text(formatConfigFileSize(command.sizeBytes))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.bar)

            Divider()

            if let desc = command.description {
                HStack(spacing: 6) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text(desc)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .background(.bar.opacity(0.5))

                Divider()
            }

            // Content
            ScrollView {
                MarkdownContentView(content: command.content, fontSize: 12)
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
            ConfigEmptyList(icon: "star", text: "No skills found")
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
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? .white : .primary)

                HStack(spacing: 4) {
                    if let desc = skill.description {
                        Text(desc)
                            .font(.system(size: 10))
                            .lineLimit(1)
                    } else {
                        Text("name: \(skill.name)")
                            .font(.system(size: 10))
                            .lineLimit(1)
                    }

                    Spacer()

                    Text(formatConfigFileSize(skill.sizeBytes))
                        .font(.system(size: 10))
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
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Text("/\(skill.name)")
                    .font(.system(size: 14, weight: .medium))

                Spacer()

                Text(formatConfigFileSize(skill.sizeBytes))
                    .font(.system(size: 10))
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
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text(desc)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .background(.bar.opacity(0.5))

                Divider()
            }

            // Body content rendered as markdown
            ScrollView {
                if skill.body.isEmpty {
                    EmptyStateView(
                        icon: "doc.text",
                        title: "No content",
                        message: "This skill has no body content beyond its metadata."
                    )
                } else {
                    MarkdownContentView(content: skill.body, fontSize: 12)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            ConfigEmptyList(icon: "point.3.connected.trianglepath.dotted", text: "No MCP servers found")
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
                    .fill(isSelected ? .white : .green)
                    .frame(width: 6, height: 6)

                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? .white : .primary)

                    Text(serverType)
                        .font(.system(size: 10))
                        .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
                }

                Spacer()

                if let level = server.level {
                    Text(level)
                        .font(.system(size: 9, weight: .medium))
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

    private var selectedServer: McpServerEntry? {
        guard let name = selectedMcpName else { return nil }
        return mcpServers.first { $0.name == name }
    }

    var body: some View {
        if let server = selectedServer {
            mcpDetailContent(server)
        } else if mcpServers.isEmpty {
            EmptyStateView(
                icon: "point.3.connected.trianglepath.dotted",
                title: "No MCP servers",
                message: "MCP servers are defined in ~/.claude/settings.json under the \"mcpServers\" key."
            )
        } else {
            EmptyStateView(
                icon: "point.3.connected.trianglepath.dotted",
                title: "Select a server",
                message: "Choose an MCP server from the sidebar to view its configuration."
            )
        }
    }

    @ViewBuilder
    private func mcpDetailContent(_ server: McpServerEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)

                Text(server.name)
                    .font(.system(size: 14, weight: .medium))

                Spacer()

                if let level = server.level {
                    Text(level)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.bar)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Type card
                    ConfigCard {
                        VStack(alignment: .leading, spacing: 8) {
                            ConfigSectionHeader(title: "TYPE")
                            Text(server.url != nil ? "HTTP (SSE)" : "Stdio")
                                .font(.system(size: 12))
                        }
                    }

                    // Connection details
                    if let url = server.url {
                        ConfigCard {
                            VStack(alignment: .leading, spacing: 8) {
                                ConfigSectionHeader(title: "URL")
                                Text(url)
                                    .font(.system(size: 12, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                    }

                    if let command = server.command {
                        ConfigCard {
                            VStack(alignment: .leading, spacing: 8) {
                                ConfigSectionHeader(title: "COMMAND")
                                HStack(spacing: 0) {
                                    Text(command)
                                        .font(.system(size: 12, design: .monospaced))

                                    if !server.args.isEmpty {
                                        Text(" " + server.args.joined(separator: " "))
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .textSelection(.enabled)
                            }
                        }
                    }

                    if !server.args.isEmpty {
                        ConfigCard {
                            VStack(alignment: .leading, spacing: 8) {
                                ConfigSectionHeader(title: "ARGUMENTS")
                                ForEach(Array(server.args.enumerated()), id: \.offset) { index, arg in
                                    HStack(spacing: 8) {
                                        Text("\(index)")
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                            .frame(width: 20, alignment: .trailing)
                                        Text(arg)
                                            .font(.system(size: 12, design: .monospaced))
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    }

                    // Environment variables (masked)
                    if !server.env.isEmpty {
                        ConfigCard {
                            VStack(alignment: .leading, spacing: 8) {
                                ConfigSectionHeader(title: "ENVIRONMENT")
                                ForEach(server.env.keys.sorted(), id: \.self) { key in
                                    HStack(spacing: 8) {
                                        Text(key)
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        Text(maskEnvValue(server.env[key] ?? ""))
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundStyle(.tertiary)
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
// MARK: - Memory
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct MemorySidebarContent: View {
    let filterText: String
    let memoryFiles: [MemoryFile]
    @Binding var selectedMemoryId: String?

    private var filtered: [MemoryFile] {
        if filterText.isEmpty { return memoryFiles }
        return memoryFiles.filter { file in
            file.label.localizedCaseInsensitiveContains(filterText) ||
            file.sublabel.localizedCaseInsensitiveContains(filterText)
        }
    }

    var body: some View {
        if filtered.isEmpty {
            ConfigEmptyList(icon: "brain", text: "No memory files found")
        } else {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(filtered) { file in
                    MemoryFileRow(
                        file: file,
                        isSelected: selectedMemoryId == file.id
                    ) {
                        selectedMemoryId = file.id
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct MemoryFileRow: View {
    let file: MemoryFile
    let isSelected: Bool
    let onSelect: () -> Void

    private var isAvailable: Bool {
        file.content != nil
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                // Availability indicator
                Circle()
                    .fill(isAvailable ? (isSelected ? .white : .green) : (isSelected ? .white.opacity(0.4) : Color.secondary.opacity(0.3)))
                    .frame(width: 6, height: 6)

                VStack(alignment: .leading, spacing: 2) {
                    Text(file.label)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? .white : (isAvailable ? .primary : .secondary))

                    Text(file.sublabel)
                        .font(.system(size: 10))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.tertiary))
                }

                Spacer()

                if let sizeBytes = file.sizeBytes {
                    Text(formatConfigFileSize(sizeBytes))
                        .font(.system(size: 10))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.tertiary))
                } else {
                    Text("missing")
                        .font(.system(size: 10))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.5)) : AnyShapeStyle(.quaternary))
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
        if let file = selectedFile {
            memoryDetailContent(file)
        } else if memoryFiles.isEmpty {
            EmptyStateView(
                icon: "brain",
                title: "No memory files",
                message: "Memory files (CLAUDE.md, MEMORY.md) were not found."
            )
        } else {
            EmptyStateView(
                icon: "brain",
                title: "Select a memory file",
                message: "Choose a file from the sidebar to view its contents."
            )
        }
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
                            .font(.system(size: 12, weight: tab.id == file.id ? .medium : .regular))
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
                    .font(.system(size: 10))
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
                    icon: "doc.questionmark",
                    title: "File not found",
                    message: file.path
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Shared Empty List
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

private struct ConfigEmptyList: View {
    let icon: String
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(.quaternary)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}
