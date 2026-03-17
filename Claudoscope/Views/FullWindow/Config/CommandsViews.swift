import SwiftUI

// MARK: - Commands

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

struct CommandRow: View {
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
