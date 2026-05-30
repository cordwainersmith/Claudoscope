import SwiftUI
import AppKit

// MARK: - Sidebar

struct PluginsSidebarContent: View {
    let filterText: String
    let plugins: [PluginInfo]
    @Binding var selectedPluginId: String?

    private var filtered: [PluginInfo] {
        guard !filterText.isEmpty else { return plugins }
        return plugins.filter { plugin in
            plugin.name.localizedCaseInsensitiveContains(filterText) ||
            plugin.fullName.localizedCaseInsensitiveContains(filterText) ||
            (plugin.marketplace ?? "").localizedCaseInsensitiveContains(filterText)
        }
    }

    var body: some View {
        if filtered.isEmpty {
            SidebarEmptyStateView(icon: "puzzlepiece.extension", text: "No plugins installed")
        } else {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(filtered) { plugin in
                    PluginRow(
                        plugin: plugin,
                        isSelected: selectedPluginId == plugin.id
                    ) {
                        selectedPluginId = plugin.id
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct PluginRow: View {
    let plugin: PluginInfo
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(plugin.name)
                        .font(Typography.bodyMedium)
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? .white : .primary)
                    if !plugin.enabled {
                        Text("disabled")
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(isSelected ? AnyShapeStyle(.white.opacity(0.2)) : AnyShapeStyle(.quaternary))
                            .clipShape(Capsule())
                            .foregroundStyle(isSelected ? .white : .secondary)
                    }
                }

                HStack(spacing: 4) {
                    if let marketplace = plugin.marketplace {
                        Text(marketplace)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Text(componentSummary)
                        .font(.system(size: 11))
                        .lineLimit(1)
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

    private var componentSummary: String {
        let count = plugin.components?.count ?? 0
        if count == 0 { return "no components" }
        return count == 1 ? "1 component" : "\(count) components"
    }
}

// MARK: - Main panel

struct PluginsMainPanelView: View {
    let plugins: [PluginInfo]
    let lintResults: [LintResult]
    @Binding var selectedPluginId: String?

    private var selectedPlugin: PluginInfo? {
        guard let id = selectedPluginId else { return nil }
        return plugins.first { $0.id == id }
    }

    var body: some View {
        if let plugin = selectedPlugin {
            PluginDetail(plugin: plugin, findings: findings(for: plugin))
        } else if plugins.isEmpty {
            EmptyStateView(
                icon: "puzzlepiece.extension",
                title: "No plugins installed",
                message: "Plugins are installed from marketplaces into ~/.claude/plugins/. Installed plugins appear here automatically."
            )
        } else if let id = selectedPluginId, plugins.first(where: { $0.id == id }) == nil {
            EmptyStateView(
                icon: "puzzlepiece.extension",
                title: "Plugin no longer installed",
                message: "The selected plugin was removed. Pick another from the sidebar."
            )
        } else {
            EmptyStateView(
                icon: "puzzlepiece.extension",
                title: "Select a plugin",
                message: "Choose a plugin from the sidebar to view its components and dependencies."
            )
        }
    }

    /// PLG results whose quoted subject names this plugin (matched by fullName).
    private func findings(for plugin: PluginInfo) -> [LintResult] {
        lintResults.filter { result in
            guard result.checkId == .PLG001 || result.checkId == .PLG002 || result.checkId == .PLG003 else {
                return false
            }
            return result.message.contains("\"\(plugin.fullName)\"")
        }
    }
}

private struct PluginDetail: View {
    let plugin: PluginInfo
    let findings: [LintResult]
    @State private var selectedComponent: PluginComponentEntry?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                metadataCard
                if !findings.isEmpty {
                    findingsCard
                }
                componentsCard
                dependenciesCard
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $selectedComponent) { entry in
            PluginComponentSheet(entry: entry)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 16))
                .foregroundStyle(Color.accentColor)
            Text(plugin.name)
                .font(.system(size: 18, weight: .semibold))
                .lineLimit(1)
            if plugin.enabled {
                Text("enabled")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.18))
                    .clipShape(Capsule())
                    .foregroundStyle(.green)
            } else {
                Text("disabled")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
            }
            Spacer()
        }
    }

    private var metadataCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            infoRow("Name", value: plugin.name)
            infoRow("Marketplace", value: plugin.marketplace)
            infoRow("Full name", value: plugin.fullName)
            infoRow("Status", value: plugin.enabled ? "Enabled" : "Disabled")
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var findingsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Dependency issues", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
            ForEach(findings) { result in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: severityIcon(result.severity))
                        .font(.system(size: 11))
                        .foregroundStyle(severityColor(result.severity))
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.message)
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                        if let fix = result.fix {
                            Text(fix)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var componentsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Components")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            let components = plugin.components ?? []
            if components.isEmpty {
                Text("This plugin contributes no components.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(components, id: \.self) { component in
                    let kind = String(component.prefix(while: { $0 != " " }))
                    let entries = plugin.componentsByKind?[kind] ?? []
                    if entries.count > 1 {
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(entries) { entry in
                                    componentButton(entry, indented: true)
                                }
                            }
                            .padding(.top, 4)
                        } label: {
                            componentLabelRow(component)
                        }
                    } else if let entry = entries.first {
                        Button { selectedComponent = entry } label: {
                            componentLabelRow(component, clickable: true)
                        }
                        .buttonStyle(.plain)
                    } else {
                        componentLabelRow(component)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func componentLabelRow(_ label: String, clickable: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 5))
                .foregroundStyle(.tertiary)
            Text(label)
                .font(Typography.code)
            if clickable {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }

    private func componentButton(_ entry: PluginComponentEntry, indented: Bool) -> some View {
        Button { selectedComponent = entry } label: {
            HStack(spacing: 8) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 4))
                    .foregroundStyle(.quaternary)
                Text(entry.name)
                    .font(Typography.code)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.leading, indented ? 14 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var dependenciesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Dependencies")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            let dependencies = plugin.dependencies ?? []
            if dependencies.isEmpty {
                Text("No declared dependencies.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(dependencies, id: \.self) { dependency in
                    HStack(spacing: 8) {
                        Image(systemName: dependencyHasIssue(dependency) ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(dependencyHasIssue(dependency) ? .orange : .green)
                        Text(dependency)
                            .font(Typography.code)
                            .textSelection(.enabled)
                        Spacer()
                    }
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func infoRow(_ label: String, value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top, spacing: 12) {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .leading)
                Text(value)
                    .font(Typography.code)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
        }
    }

    private func dependencyHasIssue(_ dependency: String) -> Bool {
        findings.contains { $0.checkId == .PLG001 && $0.message.contains("\"\(dependency)\"") }
    }

    private func severityIcon(_ severity: LintSeverity) -> String {
        switch severity {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private func severityColor(_ severity: LintSeverity) -> Color {
        switch severity {
        case .error: return .red
        case .warning: return .orange
        case .info: return .blue
        }
    }
}

// MARK: - Component content sheet

/// Shows the raw content of a plugin component (SKILL.md, an agent/command .md,
/// or a .mcp.json / hooks.json) when the user clicks it in the detail view.
private struct PluginComponentSheet: View {
    let entry: PluginComponentEntry
    @Environment(\.dismiss) private var dismiss

    private var content: String {
        (try? String(contentsOfFile: entry.path, encoding: .utf8))
            ?? "Unable to read file:\n\(entry.path)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(entry.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            ScrollView {
                Text(content)
                    .font(Typography.code)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            Divider()
            Text(entry.path)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .frame(width: 640, height: 560)
    }
}
