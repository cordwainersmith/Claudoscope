import SwiftUI

// MARK: - Memory

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

struct MemoryProjectRow: View {
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
