import SwiftUI

// MARK: - Plans Sidebar Content

struct PlansSidebarContent: View {
    let filterText: String
    let plans: [PlanSummary]
    @Binding var selectedPlanFilename: String?

    private var filteredPlans: [PlanSummary] {
        if filterText.isEmpty { return plans }
        return plans.filter { plan in
            plan.title.localizedCaseInsensitiveContains(filterText) ||
            (plan.projectHint?.localizedCaseInsensitiveContains(filterText) ?? false) ||
            plan.filename.localizedCaseInsensitiveContains(filterText)
        }
    }

    var body: some View {
        if filteredPlans.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "doc.text")
                    .font(.system(size: 24))
                    .foregroundStyle(.quaternary)
                Text("No plans found")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        } else {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(filteredPlans) { plan in
                    PlanRow(
                        plan: plan,
                        isSelected: selectedPlanFilename == plan.filename
                    ) {
                        selectedPlanFilename = plan.filename
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Plan Row

private struct PlanRow: View {
    let plan: PlanSummary
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 2) {
                Text(plan.title)
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .foregroundStyle(isSelected ? .white : .primary)

                HStack(spacing: 4) {
                    if let projectHint = plan.projectHint {
                        Text(projectHint)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(isSelected ? AnyShapeStyle(.white.opacity(0.2)) : AnyShapeStyle(.quaternary))
                            .clipShape(Capsule())
                    }

                    if let date = plan.createdAt {
                        Text(formatRelativePlanTime(date))
                            .font(.system(size: 10))
                    }

                    Spacer()

                    Text(formatFileSize(plan.sizeBytes))
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

// MARK: - Plans Main Panel View

struct PlansMainPanelView: View {
    @Binding var selectedPlanFilename: String?
    let planDetail: PlanDetail?
    let isLoading: Bool

    var body: some View {
        Group {
            if let detail = planDetail {
                planDetailContent(detail)
            } else if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyStateView(
                    icon: "doc.text",
                    title: "Select a plan",
                    message: "Choose a plan from the sidebar to view its contents."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func planDetailContent(_ detail: PlanDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Button {
                    selectedPlanFilename = nil
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Text(detail.title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)

                Spacer()

                Text(detail.filename)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.bar)

            Divider()

            // Content
            ScrollView {
                MarkdownContentView(content: detail.content, fontSize: 12)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
        }
    }
}

// MARK: - Helpers

private func formatRelativePlanTime(_ date: Date) -> String {
    let now = Date()
    let interval = now.timeIntervalSince(date)

    if interval < 60 {
        return "just now"
    } else if interval < 3600 {
        let minutes = Int(interval / 60)
        return "\(minutes)m ago"
    } else if interval < 86400 {
        let hours = Int(interval / 3600)
        return "\(hours)h ago"
    } else if interval < 604800 {
        let days = Int(interval / 86400)
        return "\(days)d ago"
    } else {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

private func formatFileSize(_ bytes: Int) -> String {
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
