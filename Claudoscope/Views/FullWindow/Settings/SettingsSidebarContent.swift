import SwiftUI

// MARK: - Settings Sidebar Content

struct SettingsSidebarContent: View {
    let filterText: String
    @Binding var selectedSection: String?

    private static let sections: [(id: String, icon: String, label: String)] = [
        ("appearance", "paintbrush", "Appearance"),
        ("model", "cpu", "Model"),
        ("permissions", "shield", "Permissions"),
        ("security", "lock.shield", "Security"),
        ("attribution", "signature", "Attribution"),
        ("plugins", "puzzlepiece", "Plugins"),
        ("account", "person.crop.circle", "Account"),
        ("general", "gear", "General"),
        ("environment", "terminal", "Environment"),
        ("pricing", "dollarsign.circle", "Pricing"),
        ("updates", "arrow.triangle.2.circlepath", "Updates"),
    ]

    private var filteredSections: [(id: String, icon: String, label: String)] {
        if filterText.isEmpty { return Self.sections }
        return Self.sections.filter { $0.label.localizedCaseInsensitiveContains(filterText) }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(filteredSections, id: \.id) { section in
                Button {
                    selectedSection = section.id
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: section.icon)
                            .font(Typography.body)
                            .frame(width: 16)
                            .foregroundStyle(selectedSection == section.id ? .white : .secondary)

                        Text(section.label)
                            .font(Typography.body)
                            .foregroundStyle(selectedSection == section.id ? .white : .primary)

                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(selectedSection == section.id ? Color.accentColor : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}
