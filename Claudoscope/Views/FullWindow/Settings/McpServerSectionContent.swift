import SwiftUI

/// Settings section for the embedded MCP server: master toggle plus status
/// and registration rows. Modeled on NotificationsSectionContent.
struct McpServerSectionContent: View {
    @Environment(McpServerService.self) private var service
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Enable MCP server", isOn: Binding(
                    get: { service.config.enabled },
                    set: { toggle(to: $0) }
                ))
                .toggleStyle(.checkbox)
                .font(Typography.body)
                .disabled(busy)

                Text("Lets Claude Code query Claudoscope: usage costs, session search, config lint, plans, and canon. Read-only, served over a local socket only this user can access. Registers the server in Claude Code automatically.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)

            if service.config.enabled {
                Divider().padding(.horizontal, 12)

                VStack(alignment: .leading, spacing: 8) {
                    statusRow
                    registrationRow
                    HStack(spacing: 4) {
                        Image(systemName: "cable.connector")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(McpServerService.socketURL.path)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 8)
        .task {
            await service.refreshClientCount()
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch service.status {
        case .stopped:
            label("circle", "Server stopped", .secondary)
        case .starting:
            label("circle.dotted", "Starting…", .secondary)
        case .running(let clients):
            label("circle.fill", clients == 1 ? "Running, 1 client connected" : "Running, \(clients) clients connected", .green)
        case .error(let message):
            label("exclamationmark.triangle", "Server error: \(message)", .orange)
        }
    }

    @ViewBuilder
    private var registrationRow: some View {
        switch service.registration {
        case .unknown, .notRegistered:
            EmptyView()
        case .registered:
            label("checkmark.circle", "Registered with Claude Code (user scope)", .secondary)
        case .failed(let message):
            label("exclamationmark.triangle", "Claude Code registration failed: \(message)", .orange)
        case .cliNotFound(let command):
            VStack(alignment: .leading, spacing: 4) {
                label("exclamationmark.triangle", "Could not find the claude CLI. Register manually:", .orange)
                HStack(spacing: 6) {
                    Text(command)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                    .font(.system(size: 11))
                }
            }
        }
    }

    private func label(_ icon: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(color == .secondary ? Color.secondary : color)
        }
    }

    private func toggle(to newValue: Bool) {
        guard !busy else { return }
        Task {
            busy = true
            if newValue {
                await service.enable()
            } else {
                await service.disable()
            }
            busy = false
        }
    }
}
