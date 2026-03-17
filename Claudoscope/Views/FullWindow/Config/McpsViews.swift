import SwiftUI

// MARK: - MCPs

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

struct McpServerRow: View {
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

struct McpServerCard: View {
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
