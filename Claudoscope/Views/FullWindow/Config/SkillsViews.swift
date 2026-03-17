import SwiftUI

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

struct SkillRow: View {
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

struct SkillMetadataCard: View {
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
