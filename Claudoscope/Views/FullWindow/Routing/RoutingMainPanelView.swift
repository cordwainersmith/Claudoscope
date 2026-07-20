import SwiftUI

// MARK: - Routing Main Panel

/// The Routing rail's main panel. Owns the install/revert/uninstall lifecycle
/// (via a `RoutingStackInstaller` actor it constructs lazily) and routes to
/// the detail view for any selected RTG lint result.
struct RoutingMainPanelView: View {
    let lintResults: [LintResult]
    let isLoading: Bool
    @Binding var selectedResultId: String?
    var onRescan: (() -> Void)?

    @Environment(SessionStore.self) private var store

    @State private var installer: RoutingStackInstaller?
    @State private var markerInfo: RoutingMarkerInfo?

    @State private var showInstallSheet = false
    @State private var showUninstallSheet = false
    @State private var showBackupsSheet = false
    @State private var showAgentFilesSheet = false

    @State private var actionInProgress: ActionKind?
    @State private var actionResult: ActionResult?

    private var rtgResults: [LintResult] {
        lintResults.filter { $0.checkId.rawValue.hasPrefix("RTG") }
    }

    private var rtgSummary: LintSummary {
        LintSummary.from(results: rtgResults)
    }

    private var isInstalled: Bool { markerInfo != nil }
    private var isDrifted: Bool { isInstalled && !rtgResults.isEmpty }

    private var ctaState: RoutingCTAState {
        if !isInstalled { return .notInstalled }
        return isDrifted ? .installedDrifted : .installedClean
    }

    var body: some View {
        Group {
            if let id = selectedResultId,
               let result = rtgResults.first(where: { $0.id == id }) {
                HealthResultDetailView(result: result, onRescan: onRescan) {
                    selectedResultId = nil
                }
            } else {
                overview
            }
        }
        .task {
            ensureInstaller()
            await refreshMarker()
            if lintResults.isEmpty {
                await store.runConfigLintIfNeeded(projectId: nil)
            }
        }
        .sheet(isPresented: $showInstallSheet) {
            RoutingInstallSheet(
                installer: installer,
                claudeDirURL: claudeDirURL,
                onCompleted: { result in
                    actionResult = result
                    Task {
                        await refreshMarker()
                        onRescan?()
                    }
                }
            )
        }
        .sheet(isPresented: $showUninstallSheet) {
            RoutingUninstallSheet(
                installer: installer,
                claudeDirURL: claudeDirURL,
                onCompleted: { result in
                    actionResult = result
                    Task {
                        await refreshMarker()
                        onRescan?()
                    }
                }
            )
        }
        .sheet(isPresented: $showBackupsSheet) {
            RoutingBackupsSheet(
                claudeDirURL: claudeDirURL,
                installer: installer,
                onChanged: {
                    Task { await refreshMarker() }
                }
            )
        }
        .sheet(isPresented: $showAgentFilesSheet) {
            RoutingAgentFilesSheet(claudeDirURL: claudeDirURL)
        }
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                titleBar
                aboutCard
                statusBanner
                if isInstalled { scoreStrip }
                primaryCTACard
                componentSummary
                quickActionsRow
                if isDrifted { driftedFixList }
            }
            .padding(.vertical, 24)
        }
    }

    // MARK: About card

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.accentColor)
                Text("About Agent Routing")
                    .font(Typography.bodyMedium)
                Spacer()
            }

            Text("Installs a set of role-scoped subagents into ~/.claude/agents/ so Claude Code can route bounded, high-volume work (lookups, broad sweeps, mechanical edits, fresh-context verification) to cheaper models instead of running everything on the main session's model. An orchestration policy block appended to ~/.claude/CLAUDE.md explains when to delegate to each role.")
                .font(Typography.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("After install, the RTG001-RTG007 lint checks below verify each piece stays in place. Reinstall refreshes files from the bundle, Revert restores the pre-install state from this install's auto-backup, and Uninstall removes routing artifacts, keeping any agent file you've edited yourself.")
                .font(Typography.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
    }

    // MARK: Title bar

    private var titleBar: some View {
        HStack(spacing: 12) {
            Text("Routing")
                .font(Typography.panelTitle)
            Spacer()
            if let onRescan {
                Button(action: onRescan) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Rescan")
            }
        }
        .padding(.horizontal, 24)
    }

    // MARK: Status banner

    private var statusBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: isInstalled ? "checkmark.seal.fill" : "arrow.triangle.branch")
                .font(.system(size: 14))
                .foregroundStyle(isInstalled ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                if let info = markerInfo {
                    Text("Routing stack installed \(info.installedAtDisplay)")
                        .font(Typography.bodyMedium)
                        .foregroundStyle(.primary)
                    Text("Marker: ~/.claude/\(RoutingStackInstaller.markerFileName)")
                        .font(Typography.codeSmall)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Not installed")
                        .font(Typography.bodyMedium)
                        .foregroundStyle(.primary)
                    Text("Install the routing stack to add cost-aware subagent roles and an orchestration policy to ~/.claude.")
                        .font(Typography.body)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
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
    }

    // MARK: Score strip

    private var scoreStrip: some View {
        HStack(spacing: 12) {
            HealthGaugeCard(summary: rtgSummary)
                .frame(width: 160)

            HealthStatCard(
                label: "Errors",
                count: rtgSummary.errorCount,
                color: colorForSeverity(.error),
                descriptor: descriptor(for: .error)
            )
            HealthStatCard(
                label: "Warnings",
                count: rtgSummary.warningCount,
                color: colorForSeverity(.warning),
                descriptor: descriptor(for: .warning)
            )
            HealthStatCard(
                label: "Info",
                count: rtgSummary.infoCount,
                color: colorForSeverity(.info),
                descriptor: descriptor(for: .info)
            )
        }
        .padding(.horizontal, 24)
    }

    private func descriptor(for severity: LintSeverity) -> String {
        let count = rtgResults.filter { $0.severity == severity }.count
        return count == 0 ? "Clean" : "\(count) RTG"
    }

    // MARK: Primary CTA card

    private var primaryCTACard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: ctaIcon)
                    .font(.system(size: 18))
                    .foregroundStyle(ctaIconColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ctaTitle)
                        .font(Typography.bodyMedium)
                    Text(ctaSubtitle)
                        .font(Typography.body)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                primaryButton
                if isInstalled {
                    Button("Revert") {
                        runRevert()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(actionInProgress != nil)
                    .help("Restore the pre-install state from this install's backup.")

                    Button("Uninstall") {
                        showUninstallSheet = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .tint(.red)
                    .disabled(actionInProgress != nil)
                    .help("Remove routing stack artifacts, keeping any agent file you've edited yourself.")
                }
                Spacer()
                if let action = actionInProgress {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(action.label)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
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
    }

    private var ctaIcon: String {
        switch ctaState {
        case .notInstalled: return "arrow.triangle.branch"
        case .installedClean: return "checkmark.shield.fill"
        case .installedDrifted: return "exclamationmark.shield.fill"
        }
    }

    private var ctaIconColor: Color {
        switch ctaState {
        case .notInstalled: return Color.accentColor
        case .installedClean: return Color.green
        case .installedDrifted: return Color.orange
        }
    }

    private var ctaTitle: String {
        switch ctaState {
        case .notInstalled: return "Install Agent Routing Stack"
        case .installedClean: return "Routing stack is current"
        case .installedDrifted: return "Routing stack has drifted"
        }
    }

    private var ctaSubtitle: String {
        switch ctaState {
        case .notInstalled:
            return "Adds role-scoped subagents and an orchestration policy so bounded work can run on cheaper models."
        case .installedClean:
            return "All routing checks pass. Reinstall to refresh files from the bundled stack."
        case .installedDrifted:
            return "\(rtgResults.count) routing check(s) failing. Reinstall restores canonical files; per-rule fixes appear below."
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch ctaState {
        case .notInstalled:
            Button("Install Routing Stack") {
                showInstallSheet = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(actionInProgress != nil)
        case .installedClean, .installedDrifted:
            Button("Reinstall") {
                showInstallSheet = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(actionInProgress != nil)
        }
    }

    private func actionResultRow(_ result: ActionResult) -> some View {
        HStack(spacing: 8) {
            Image(systemName: result.isError ? "exclamationmark.octagon.fill" : "checkmark.circle.fill")
                .foregroundStyle(result.isError ? .red : .green)
            Text(result.message)
                .font(Typography.body)
                .foregroundStyle(.primary)
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
        .background(
            (result.isError ? Color.red : Color.green).opacity(0.08)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
    }

    // MARK: Component summary

    private var componentSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("COMPONENTS")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 24)

            HStack(spacing: 10) {
                ForEach(ComponentCardSpec.all, id: \.id) { spec in
                    ComponentCard(
                        spec: spec,
                        installed: spec.isInstalled(markerInfo),
                        failingCount: failingCount(in: spec)
                    )
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private func failingCount(in spec: ComponentCardSpec) -> Int {
        rtgResults.filter(spec.matches).count
    }

    // MARK: Quick actions

    private var quickActionsRow: some View {
        HStack(spacing: 8) {
            Button {
                showBackupsSheet = true
            } label: {
                Label("Backups", systemImage: "externaldrive.badge.timemachine")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            Button {
                showAgentFilesSheet = true
            } label: {
                Label("Agent Files", systemImage: "person.2.badge.gearshape")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            Spacer()
        }
        .padding(.horizontal, 24)
    }

    // MARK: Drifted fix list

    private var driftedFixList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("FAILING CHECKS")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)

            VStack(spacing: 4) {
                ForEach(rtgResults) { result in
                    RoutingDriftFixRow(result: result) {
                        selectedResultId = result.id
                    }
                }
            }
        }
        .padding(.horizontal, 24)
    }

    // MARK: Lifecycle helpers

    private var claudeDirURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    private func ensureInstaller() {
        if installer == nil {
            let dir = claudeDirURL
            installer = RoutingStackInstaller(
                claudeDir: dir,
                payloadProvider: { try RoutingStackPayloadLoader.loadFromBundle() },
                setInstallInProgress: { [weak store] value in store?.setInstallInProgress(value) }
            )
        }
    }

    private func refreshMarker() async {
        let url = claudeDirURL.appendingPathComponent(RoutingStackInstaller.markerFileName)
        let info = RoutingMarkerInfo.load(from: url)
        await MainActor.run { self.markerInfo = info }
    }

    private func runRevert() {
        guard let installer else { return }
        actionInProgress = .revert
        actionResult = nil
        Task {
            do {
                try await installer.revert()
                await MainActor.run {
                    actionInProgress = nil
                    actionResult = ActionResult(message: "Reverted from backup. Pre-install state restored.", isError: false)
                }
                await refreshMarker()
                onRescan?()
            } catch {
                await MainActor.run {
                    actionInProgress = nil
                    actionResult = ActionResult(message: String(describing: error), isError: true)
                }
            }
        }
    }
}

// MARK: - Drift fix row

private struct RoutingDriftFixRow: View {
    let result: LintResult
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: severityIcon(result.severity))
                .font(.system(size: 12))
                .foregroundStyle(colorForSeverity(result.severity))
                .frame(width: 16)
            Text(result.checkId.rawValue)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(colorForSeverity(result.severity))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(colorForSeverity(result.severity).opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Text(displayLabel(for: result))
                .font(Typography.body)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Details") {
                onSelect()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }
}

// MARK: - Component card

private struct ComponentCard: View {
    let spec: ComponentCardSpec
    let installed: Bool
    let failingCount: Int

    private var passing: Bool { installed && failingCount == 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .font(.system(size: 13))
                    .foregroundStyle(iconColor)
                Text(spec.label)
                    .font(Typography.bodyMedium)
                Spacer()
            }
            Text(spec.subtitle)
                .font(Typography.codeSmall)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            HStack(spacing: 4) {
                Text(statusLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(passing ? .green : (installed ? .orange : .secondary))
                Spacer()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }

    private var iconName: String {
        if !installed { return "circle.dashed" }
        return passing ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var iconColor: Color {
        if !installed { return .secondary }
        return passing ? Color.green : Color.orange
    }

    private var statusLabel: String {
        if !installed { return "Not installed" }
        return passing ? "Pass" : "\(failingCount) failing"
    }
}

// MARK: - Component spec

private struct ComponentCardSpec {
    let id: String
    let label: String
    let subtitle: String
    let isInstalled: (RoutingMarkerInfo?) -> Bool
    let matches: (LintResult) -> Bool

    static let all: [ComponentCardSpec] = {
        let coreNames = Set(RoutingStackPayloadLoader.coreAgentFileNames)
        let securityNames = Set(RoutingStackPayloadLoader.securityAgentFileNames)
        return [
            ComponentCardSpec(
                id: "core",
                label: "Core Agents",
                subtitle: "recon, Explore, routine, builder, checker",
                isInstalled: { $0?.coreInstalled ?? false },
                matches: { result in
                    (result.checkId == .RTG001 || result.checkId == .RTG002)
                        && coreNames.contains(where: result.filePath.hasSuffix)
                }
            ),
            ComponentCardSpec(
                id: "security",
                label: "Security Pair",
                subtitle: "security-review, security-build",
                isInstalled: { $0?.securityInstalled ?? false },
                matches: { result in
                    (result.checkId == .RTG001 || result.checkId == .RTG002)
                        && securityNames.contains(where: result.filePath.hasSuffix)
                }
            ),
            ComponentCardSpec(
                id: "policy",
                label: "Policy Block",
                subtitle: "CLAUDE.md orchestration section",
                isInstalled: { $0?.policyInstalled ?? false },
                matches: { $0.checkId == .RTG003 || $0.checkId == .RTG004 }
            ),
            ComponentCardSpec(
                id: "fallback",
                label: "Fallback Model",
                subtitle: "settings.json fallbackModel",
                isInstalled: { $0?.fallbackModelSet ?? false },
                matches: { $0.checkId == .RTG005 }
            ),
        ]
    }()
}

// MARK: - CTA state

private enum RoutingCTAState {
    case notInstalled
    case installedClean
    case installedDrifted
}

// MARK: - Marker info

struct RoutingMarkerInfo {
    let installedAt: Date?
    let backupPath: URL?
    let coreInstalled: Bool
    let securityInstalled: Bool
    let policyInstalled: Bool
    let fallbackModelSet: Bool
    let fallbackModelValue: [String]?

    var installedAtDisplay: String {
        guard let installedAt else { return "(unknown date)" }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: installedAt)
    }

    static func load(from url: URL) -> RoutingMarkerInfo? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let isoFull = ISO8601DateFormatter()
        isoFull.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoBasic = ISO8601DateFormatter()
        isoBasic.formatOptions = [.withInternetDateTime]

        var date: Date?
        if let s = dict["installedAt"] as? String {
            date = isoFull.date(from: s) ?? isoBasic.date(from: s)
        }

        let backup = (dict["backupPath"] as? String).map { URL(fileURLWithPath: $0) }

        return RoutingMarkerInfo(
            installedAt: date,
            backupPath: backup,
            coreInstalled: dict["coreInstalled"] as? Bool ?? false,
            securityInstalled: dict["securityInstalled"] as? Bool ?? false,
            policyInstalled: dict["policyInstalled"] as? Bool ?? false,
            fallbackModelSet: dict["fallbackModelSet"] as? Bool ?? false,
            fallbackModelValue: dict["fallbackModelValue"] as? [String]
        )
    }
}
