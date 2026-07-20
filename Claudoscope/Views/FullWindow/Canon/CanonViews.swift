import SwiftUI

// MARK: - Sidebar

enum CanonRowStatus {
    case enabled
    case detected
    case none

    var color: Color {
        switch self {
        case .enabled:  return .green
        case .detected: return .orange
        case .none:     return Color.secondary.opacity(0.3)
        }
    }

    var help: String {
        switch self {
        case .enabled:  return "Canon enabled"
        case .detected: return "Canon detected on disk (not enabled here)"
        case .none:     return "Canon not enabled"
        }
    }
}

struct CanonSidebarContent: View {
    let filterText: String
    let projects: [Project]
    let detectedProjectIds: Set<String>
    @Binding var selectedProjectId: String?
    @Environment(CanonService.self) private var canonService

    private var filteredProjects: [Project] {
        if filterText.isEmpty { return projects }
        return projects.filter { $0.name.localizedCaseInsensitiveContains(filterText) }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(filteredProjects) { project in
                CanonProjectRow(
                    name: project.name,
                    status: status(for: project),
                    isSelected: selectedProjectId == project.id
                ) {
                    selectedProjectId = project.id
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func status(for project: Project) -> CanonRowStatus {
        if canonService.isOptedIn(project.id) { return .enabled }
        if detectedProjectIds.contains(project.id) { return .detected }
        return .none
    }
}

private struct CanonProjectRow: View {
    let name: String
    let status: CanonRowStatus
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Circle()
                    .fill(status.color)
                    .frame(width: 7, height: 7)
                    .help(status.help)

                Text(name)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? .white : .primary)

                Spacer()
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

// MARK: - Main panel

struct CanonMainPanelView: View {
    let selectedProjectId: String?
    @Environment(SessionStore.self) private var store
    @Environment(CanonService.self) private var canonService

    @State private var kindFilter: CanonKind?
    @State private var hideSuperseded = false
    @State private var busy = false
    @State private var actionResult: ActionResult?
    @State private var showDisableConfirm = false

    private var project: Project? {
        store.projects.first { $0.id == selectedProjectId }
    }

    /// Only trust canonData when it matches the selected project (it is loaded
    /// asynchronously, so it can briefly lag a project switch).
    private var data: CanonData? {
        guard let selectedProjectId, store.canonData?.projectId == selectedProjectId else { return nil }
        return store.canonData
    }

    private var isOptedIn: Bool {
        selectedProjectId.map { canonService.isOptedIn($0) } ?? false
    }

    var body: some View {
        Group {
            if let project {
                content(project)
            } else {
                EmptyStateView(
                    icon: "building.columns",
                    title: "Select a project",
                    message: "Choose a project from the sidebar to view its canon."
                )
            }
        }
    }

    private func content(_ project: Project) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                titleBar
                statusBanner(project)
                recordsSection
            }
            .padding(.vertical, 24)
        }
    }

    // MARK: Title

    private var titleBar: some View {
        HStack(spacing: 12) {
            Text("Canon")
                .font(Typography.panelTitle)
            Spacer()
        }
        .padding(.horizontal, 24)
    }

    // MARK: Status banner

    @ViewBuilder
    private func statusBanner(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: bannerIcon)
                    .font(.system(size: 16))
                    .foregroundStyle(bannerColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bannerTitle)
                        .font(Typography.bodyMedium)
                    Text(bannerSubtitle)
                        .font(Typography.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            if isOptedIn, !issues.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(issues, id: \.self) { issue in
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                            Text(issue)
                                .font(Typography.body)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                if isOptedIn {
                    Button("Reinstall protocol") { runEnable(project) }
                        .buttonStyle(.bordered)
                        .disabled(busy)
                        .help("Refresh .claude/rules/canon.md from the bundled protocol. Records are untouched.")
                    Button("Disable") { showDisableConfirm = true }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .disabled(busy)
                        .help("Remove the protocol rule. Your canon.md records are kept.")
                } else {
                    Button("Enable Canon") { runEnable(project) }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy)
                }
                if busy {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }

            if let result = actionResult {
                actionResultRow(result)
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
        .padding(.horizontal, 24)
        .confirmationDialog(
            "Disable Canon for this project?",
            isPresented: $showDisableConfirm,
            titleVisibility: .visible
        ) {
            Button("Disable (keep records)", role: .destructive) { runDisable(project) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes .claude/rules/canon.md. Your .claude/canon.md records stay on disk.")
        }
    }

    private var detectedOnDisk: Bool {
        (data?.rawExists ?? false) || (data?.protocolInstalled ?? false)
    }

    private var bannerIcon: String {
        if isOptedIn { return issues.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill" }
        return detectedOnDisk ? "eye" : "building.columns"
    }

    private var bannerColor: Color {
        if isOptedIn { return issues.isEmpty ? .green : .orange }
        return detectedOnDisk ? .orange : Color.accentColor
    }

    private var bannerTitle: String {
        if isOptedIn { return issues.isEmpty ? "Canon enabled" : "Canon enabled, needs attention" }
        return detectedOnDisk ? "Canon detected in this repo" : "Canon not enabled"
    }

    private var bannerSubtitle: String {
        if isOptedIn {
            return "Claude Code follows the protocol in .claude/rules/canon.md and appends records to .claude/canon.md with your consent."
        }
        if detectedOnDisk {
            return "This repo already has canon artifacts (installed by a teammate or an earlier setup). Records are shown below. Enable to manage and lint it on this machine."
        }
        return "Install the canon protocol so Claude Code records settled engineering decisions in .claude/canon.md, committed with your repo."
    }

    /// Banner issues, computed from canonData + the shared pure checks — the same
    /// checks the CAN lint family reports, so the two never disagree.
    private var issues: [String] {
        guard let data else { return [] }
        var out: [String] = []
        if !data.protocolInstalled {
            out.append("Protocol rule .claude/rules/canon.md is missing.")
        } else if (data.protocolVersion ?? 0) < canonService.bundledProtocolVersion {
            out.append("Protocol is outdated (v\(data.protocolVersion.map(String.init) ?? "unknown") vs v\(canonService.bundledProtocolVersion)). Reinstall to update.")
        }
        if data.recordsGitignored == true {
            out.append("Records are gitignored, so they won't be shared with your team.")
        }
        let malformed = CanonParsing.malformedRecords(data.records).count
        if malformed > 0 {
            out.append("\(malformed) record(s) are malformed.")
        }
        let dangling = CanonParsing.danglingSupersedes(data.records).count
        if dangling > 0 {
            out.append("\(dangling) supersede pointer(s) don't resolve.")
        }
        return out
    }

    private func actionResultRow(_ result: ActionResult) -> some View {
        HStack(spacing: 8) {
            Image(systemName: result.isError ? "exclamationmark.octagon.fill" : "checkmark.circle.fill")
                .foregroundStyle(result.isError ? .red : .green)
            Text(result.message)
                .font(Typography.body)
            Spacer()
            Button {
                actionResult = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background((result.isError ? Color.red : Color.green).opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
    }

    // MARK: Records

    private var filteredRecords: [CanonRecord] {
        guard let records = data?.records else { return [] }
        return records.filter { record in
            if let kindFilter, record.kind != kindFilter { return false }
            if hideSuperseded, isSuperseded(record) { return false }
            return true
        }
    }

    private func isSuperseded(_ record: CanonRecord) -> Bool {
        switch record.status {
        case .superseded, .nonCanonNoPointer: return true
        default: return false
        }
    }

    @ViewBuilder
    private var recordsSection: some View {
        let hasRecords = !(data?.records.isEmpty ?? true)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("RECORDS")
                    .font(Typography.caption)
                    .foregroundStyle(.tertiary)
                if hasRecords {
                    Text("\(data?.records.count ?? 0)")
                        .font(Typography.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if hasRecords {
                    Picker("Kind", selection: $kindFilter) {
                        Text("All kinds").tag(CanonKind?.none)
                        ForEach(CanonKind.allCases, id: \.self) { kind in
                            Text(kind.label).tag(CanonKind?.some(kind))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 140)

                    Toggle("Hide superseded", isOn: $hideSuperseded)
                        .toggleStyle(.checkbox)
                        .font(Typography.body)
                }
            }
            .padding(.horizontal, 24)

            if !hasRecords {
                EmptyStateView(
                    icon: "text.book.closed",
                    title: "No records yet",
                    message: "Records appear here as Claude appends them during sessions, once a decision is settled with your consent."
                )
                .frame(minHeight: 220)
            } else {
                VStack(spacing: 10) {
                    ForEach(filteredRecords) { record in
                        CanonRecordCard(record: record)
                    }
                }
                .padding(.horizontal, 24)
            }
        }
    }

    // MARK: Actions

    private func runEnable(_ project: Project) {
        busy = true
        actionResult = nil
        Task {
            do {
                let result = try await store.enableCanon(projectId: project.id)
                busy = false
                actionResult = ActionResult(
                    message: result.seededDataFile
                        ? "Canon enabled. Protocol installed and canon.md seeded."
                        : "Canon protocol installed.",
                    isError: false
                )
            } catch {
                busy = false
                actionResult = ActionResult(message: "Enable failed: \(error)", isError: true)
            }
        }
    }

    private func runDisable(_ project: Project) {
        busy = true
        actionResult = nil
        Task {
            do {
                try await store.disableCanon(projectId: project.id)
                busy = false
                actionResult = ActionResult(message: "Canon disabled. Your records were kept on disk.", isError: false)
            } catch {
                busy = false
                actionResult = ActionResult(message: "Disable failed: \(error)", isError: true)
            }
        }
    }
}

// MARK: - Settings section

/// The Canon section shown in Settings: bulk enable/disable across every known
/// project. Bulk enable writes into many repos at once, so both actions are
/// gated behind a confirmation dialog and report a result summary.
struct CanonSettingsSectionContent: View {
    @Environment(SessionStore.self) private var store
    @Environment(CanonService.self) private var canonService

    @State private var busy = false
    @State private var result: CanonBulkResult?
    @State private var resultIsEnable = true
    @State private var showEnableAllConfirm = false
    @State private var showDisableAllConfirm = false

    private var eligibleCount: Int { store.canonEligibleProjectIds.count }
    private var enabledCount: Int { store.canonEligibleProjectIds.filter { canonService.isOptedIn($0) }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Canon installs a per-project decision-records protocol into each repo's .claude/, so Claude Code captures settled engineering decisions in a file committed with your code. Manage individual projects from the Canon rail.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("\(enabledCount) of \(eligibleCount) eligible projects enabled")
                .font(.system(size: 12, weight: .medium))

            HStack(spacing: 8) {
                Button("Enable Canon for all projects") { showEnableAllConfirm = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || eligibleCount == 0)
                Button("Disable for all") { showDisableAllConfirm = true }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(busy || enabledCount == 0)
                if busy { ProgressView().controlSize(.small) }
                Spacer()
            }

            if let result {
                resultRow(result)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .confirmationDialog(
            "Enable Canon for all \(eligibleCount) projects?",
            isPresented: $showEnableAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Enable for all") { runEnableAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Writes .claude/rules/canon.md and seeds .claude/canon.md into every eligible project (git repo roots and standalone folders). Container folders and repo subdirectories are skipped so canon never cascades into nested projects. Existing records are never overwritten.")
        }
        .confirmationDialog(
            "Disable Canon for all \(enabledCount) enabled projects?",
            isPresented: $showDisableAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Disable for all (keep records)", role: .destructive) { runDisableAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes .claude/rules/canon.md from each enabled project. Your .claude/canon.md records stay on disk.")
        }
    }

    private func resultRow(_ r: CanonBulkResult) -> some View {
        var parts = ["\(resultIsEnable ? "Enabled" : "Disabled") \(r.succeeded) project(s)"]
        if r.skippedIneligible > 0 { parts.append("skipped \(r.skippedIneligible) (containers/subdirs)") }
        if r.skipped > 0 { parts.append("skipped \(r.skipped) (folder not found)") }
        if r.failed > 0 { parts.append("\(r.failed) failed") }
        let summary = parts.joined(separator: ", ") + "."
        let bad = r.failed > 0
        return HStack(spacing: 8) {
            Image(systemName: bad ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(bad ? .orange : .green)
            Text(summary)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(8)
        .background((bad ? Color.orange : Color.green).opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func runEnableAll() {
        busy = true
        result = nil
        resultIsEnable = true
        Task {
            let r = await store.enableCanonForAllProjects()
            busy = false
            result = r
        }
    }

    private func runDisableAll() {
        busy = true
        result = nil
        resultIsEnable = false
        Task {
            let r = await store.disableCanonForAllProjects()
            busy = false
            result = r
        }
    }
}

// MARK: - Record card

private struct CanonRecordCard: View {
    let record: CanonRecord

    private var superseded: Bool {
        switch record.status {
        case .superseded, .nonCanonNoPointer: return true
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(record.title)
                    .font(Typography.bodyMedium)
                    .foregroundStyle(.primary)
                Spacer()
            }

            HStack(spacing: 6) {
                if let kind = record.kind {
                    badge(kind.label, color: kindColor(kind))
                }
                if let date = record.dateString {
                    Text(date)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                statusBadge
            }

            if !record.body.isEmpty {
                MarkdownContentView(content: record.body, fontSize: 12)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        .opacity(superseded ? 0.6 : 1.0)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch record.status {
        case .canon:
            badge("canon", color: .green)
        case .superseded:
            badge("superseded", color: .orange)
        case .nonCanonNoPointer:
            badge("non-canon", color: .secondary)
        case .unknown:
            badge("invalid", color: .red)
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    private func kindColor(_ kind: CanonKind) -> Color {
        switch kind {
        case .choice:     return Color(red: 0.216, green: 0.541, blue: 0.867)
        case .constraint: return Color(red: 0.886, green: 0.294, blue: 0.290)
        case .convention: return Color(red: 0.498, green: 0.467, blue: 0.867)
        case .gotcha:     return Color(red: 0.937, green: 0.624, blue: 0.153)
        }
    }
}
