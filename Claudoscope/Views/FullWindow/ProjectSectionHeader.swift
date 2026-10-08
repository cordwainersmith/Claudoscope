import SwiftUI

/// Collapsible project header for the Sessions and Tools sidebars. Both
/// sidebars are one `LazyVStack` of `Section`s so rows are realized only as
/// they scroll into view; a per-project `VStack` realized every row of every
/// expanded project, which put thousands of text lines and symbol images in
/// memory for a window that shows about twenty-five.
struct ProjectSectionHeader: View {
    let project: Project
    let count: Int
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)

                Text(project.name)
                    .font(Typography.bodyMedium)
                    .lineLimit(1)
                    .help(project.name)

                Spacer()

                Text("\(count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
