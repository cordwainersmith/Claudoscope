import SwiftUI
import AppKit

// MARK: - Agent Files Sheet

/// Master-detail viewer for the routing stack's role agents. The left pane lists
/// the seven agents grouped Core / Security; the right pane renders the selected
/// agent's markdown with a styled frontmatter header. Shows the on-disk file when
/// installed (so edits are visible), otherwise the bundled payload content.
struct RoutingAgentFilesSheet: View {
    let claudeDirURL: URL

    @Environment(\.dismiss) private var dismiss

    @State private var entries: [RoutingAgentEntry] = []
    @State private var selectedFileName: String?

    private var agentsDir: URL { claudeDirURL.appendingPathComponent("agents") }

    private var selectedEntry: RoutingAgentEntry? {
        entries.first { $0.fileName == selectedFileName }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if entries.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    master
                        .frame(width: 230)
                    Divider()
                    detail
                        .frame(maxWidth: .infinity)
                }
            }
            Divider()
            footer
        }
        .frame(width: 760)
        .frame(minHeight: 520)
        .task { reload() }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.2.badge.gearshape")
                .font(.system(size: 18))
                .foregroundStyle(Color.accentColor)
            Text("Agent Files")
                .font(Typography.panelTitle)
            Spacer()
            Button {
                reload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Refresh")
        }
        .padding(Spacing.lg)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(Spacing.lg)
    }

    private var emptyState: some View {
        HStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
            Text("Bundled routing stack resources are unavailable.")
                .font(Typography.body)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: Master list

    private var master: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                group(label: "CORE", items: entries.filter { $0.group == .core })
                group(label: "SECURITY", items: entries.filter { $0.group == .security })
            }
            .padding(.vertical, 8)
        }
        .background(Color.cardBackground.opacity(0.35))
    }

    @ViewBuilder
    private func group(label: String, items: [RoutingAgentEntry]) -> some View {
        if !items.isEmpty {
            Text(label)
                .font(Typography.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)
            ForEach(items) { entry in
                RoutingAgentRow(
                    entry: entry,
                    isSelected: selectedFileName == entry.fileName
                ) {
                    selectedFileName = entry.fileName
                }
            }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let entry = selectedEntry {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    RoutingAgentHeaderCard(entry: entry)
                    RichMarkdownContentView(content: entry.body)
                }
                .padding(Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(entry.fileName)
        } else {
            Text("Select an agent to view its instructions.")
                .font(Typography.body)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Load

    private func reload() {
        guard let payload = try? RoutingStackPayloadLoader.loadFromBundle() else {
            entries = []
            return
        }
        let loaded = RoutingAgentEntry.load(payload: payload, agentsDir: agentsDir)
        entries = loaded
        if selectedFileName == nil || !loaded.contains(where: { $0.fileName == selectedFileName }) {
            selectedFileName = loaded.first?.fileName
        }
    }
}

// MARK: - Master row

private struct RoutingAgentRow: View {
    let entry: RoutingAgentEntry
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Text(entry.roleName)
                    .font(Typography.body)
                    .foregroundStyle(isSelected ? .white : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if entry.source == .edited {
                    Circle()
                        .fill(isSelected ? Color.white : Color.orange)
                        .frame(width: 5, height: 5)
                        .help("Edited since install")
                }
                Spacer(minLength: 4)
                if let model = entry.model {
                    Text(model)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(isSelected ? .white : .secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            isSelected
                                ? AnyShapeStyle(Color.white.opacity(0.18))
                                : AnyShapeStyle(Color.primary.opacity(0.06))
                        )
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                isSelected
                    ? Color.accentColor
                    : (isHovered ? Color.primary.opacity(0.04) : .clear)
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Detail header card

private struct RoutingAgentHeaderCard: View {
    let entry: RoutingAgentEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(entry.roleName)
                    .font(Typography.panelTitle)
                sourceBadge
                Spacer()
                if let url = entry.onDiskURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if !chips.isEmpty {
                HStack(spacing: 6) {
                    ForEach(chips, id: \.self) { chip in
                        Text(chip)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(Capsule())
                    }
                }
            }

            if let description = entry.description, !description.isEmpty {
                Text(description)
                    .font(Typography.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }

    /// model + effort + tools, in that order, omitting anything missing.
    private var chips: [String] {
        var out: [String] = []
        if let model = entry.model { out.append(model) }
        if let effort = entry.effort { out.append("effort: \(effort)") }
        out.append(contentsOf: entry.tools)
        return out
    }

    private var sourceBadge: some View {
        let (label, color): (String, Color) = switch entry.source {
        case .installed: ("Installed", .green)
        case .edited: ("Edited", .orange)
        case .bundledOnly: ("Bundled preview", .secondary)
        }
        return Text(label.uppercased())
            .font(Typography.micro)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}

// MARK: - Agent entry model

/// One role agent for the viewer. `load` is a pure builder (no `Bundle.main`,
/// no view state) so the installed / edited / bundled-only classification is
/// unit-testable.
struct RoutingAgentEntry: Identifiable {
    enum Source {
        case installed      // on disk, byte-identical to the bundled payload
        case edited         // on disk, differs from the bundled payload
        case bundledOnly    // not installed; showing the bundled content
    }

    let fileName: String
    let roleName: String
    let group: RoutingStackPayload.Group
    let model: String?
    let effort: String?
    let tools: [String]
    let description: String?
    let body: String
    let onDiskURL: URL?
    let source: Source

    var id: String { fileName }

    static func load(payload: RoutingStackPayload, agentsDir: URL) -> [RoutingAgentEntry] {
        let fm = FileManager.default
        return payload.agentFiles.map { file in
            let liveURL = agentsDir.appendingPathComponent(file.fileName)
            let onDisk = try? String(contentsOf: liveURL, encoding: .utf8)

            let content: String
            let source: Source
            let onDiskURL: URL?
            if let onDisk, fm.fileExists(atPath: liveURL.path) {
                content = onDisk
                onDiskURL = liveURL
                let matchesBundle = InstallerFileOps.sha256(of: onDisk) == payload.contentHash(forAgent: file.fileName)
                source = matchesBundle ? .installed : .edited
            } else {
                content = file.content
                onDiskURL = nil
                source = .bundledOnly
            }

            let parsed = parseFrontmatter(content)
            let tools = (parsed.metadata["tools"] ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            return RoutingAgentEntry(
                fileName: file.fileName,
                roleName: parsed.name ?? (file.fileName as NSString).deletingPathExtension,
                group: file.group,
                model: parsed.metadata["model"],
                effort: parsed.metadata["effort"],
                tools: tools,
                description: parsed.description,
                body: parsed.body,
                onDiskURL: onDiskURL,
                source: source
            )
        }
    }
}
