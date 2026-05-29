import SwiftUI

// MARK: - Hardening Main Panel

/// The Hardening rail's main panel. Owns the install/revert/uninstall lifecycle
/// (via a `HardeningInstaller` actor it constructs lazily) and routes to the
/// detail view for any selected HRD lint result.
struct HardeningMainPanelView: View {
    let lintResults: [LintResult]
    let isLoading: Bool
    @Binding var selectedResultId: String?
    var onRescan: (() -> Void)?

    @Environment(SessionStore.self) private var store

    @State private var installer: HardeningInstaller?
    @State private var markerInfo: MarkerInfo?

    @State private var showInstallSheet = false
    @State private var showUninstallSheet = false
    @State private var showTrustedSourcesSheet = false
    @State private var showBackupsSheet = false

    @State private var actionInProgress: ActionKind?
    @State private var actionResult: ActionResult?

    private var hrdResults: [LintResult] {
        lintResults.filter { $0.checkId.rawValue.hasPrefix("HRD") }
    }

    private var hrdSummary: LintSummary {
        LintSummary.from(results: hrdResults)
    }

    private var isInstalled: Bool { markerInfo != nil }
    private var isDrifted: Bool { isInstalled && !hrdResults.isEmpty }

    private var ctaState: CTAState {
        if !isInstalled { return .notInstalled }
        return isDrifted ? .installedDrifted : .installedClean
    }

    var body: some View {
        Group {
            if let id = selectedResultId,
               let result = hrdResults.first(where: { $0.id == id }) {
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
            // If the lint hasn't been computed yet, kick it off so the rail isn't blank.
            if lintResults.isEmpty {
                await store.runConfigLintIfNeeded(projectId: nil)
            }
        }
        .sheet(isPresented: $showInstallSheet) {
            HardeningInstallSheet(
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
            HardeningUninstallSheet(
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
        .sheet(isPresented: $showTrustedSourcesSheet) {
            TrustedSourcesSheet(
                claudeDirURL: claudeDirURL,
                onSaved: {
                    onRescan?()
                }
            )
        }
        .sheet(isPresented: $showBackupsSheet) {
            HardeningBackupsSheet(
                claudeDirURL: claudeDirURL,
                installer: installer,
                onChanged: {
                    Task { await refreshMarker() }
                }
            )
        }
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                titleBar
                aboutCard
                statusBanner
                scoreStrip
                primaryCTACard
                layerSummary
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
                Text("About Hardening")
                    .font(Typography.bodyMedium)
                Spacer()
            }

            Text("Claudoscope's hardening rail installs a vendor-neutral security baseline into ~/.claude across five layers shown below: Layer 1 enforces deny rules and sandbox isolation, Layer 2 wires PreToolUse and PostToolUse shell hooks for credential scans and command vetting, Layer 3 adds autoMode soft-deny rules, Layer 4 appends a marker-wrapped governance block to CLAUDE.md, and the Skill layer deploys a security-awareness skill agents can consult on demand.")
                .font(Typography.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("After install, the HRD001-HRD011 lint checks below verify each layer stays in place. Click any failing check for an explanation and remediation. Reinstall refreshes files from the bundle, Revert restores the pre-install state from this install's auto-backup, and Uninstall surgically removes every Claudoscope artifact.")
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
            Text("Hardening")
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
            Image(systemName: isInstalled ? "checkmark.seal.fill" : "exclamationmark.shield")
                .font(.system(size: 14))
                .foregroundStyle(isInstalled ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                if let info = markerInfo {
                    Text("Baseline installed \(info.installedAtDisplay)")
                        .font(Typography.bodyMedium)
                        .foregroundStyle(.primary)
                    Text("Marker: ~/.claude/\(HardeningInstaller.markerFileName)")
                        .font(Typography.codeSmall)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Not installed")
                        .font(Typography.bodyMedium)
                        .foregroundStyle(.primary)
                    Text("Install the baseline to harden ~/.claude with deny rules, sandbox, hooks, autoMode, governance, and a security-awareness skill.")
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
            HealthGaugeCard(summary: hrdSummary)
                .frame(width: 160)

            HealthStatCard(
                label: "Errors",
                count: hrdSummary.errorCount,
                color: colorForSeverity(.error),
                descriptor: descriptor(for: .error)
            )
            HealthStatCard(
                label: "Warnings",
                count: hrdSummary.warningCount,
                color: colorForSeverity(.warning),
                descriptor: descriptor(for: .warning)
            )
            HealthStatCard(
                label: "Info",
                count: hrdSummary.infoCount,
                color: colorForSeverity(.info),
                descriptor: descriptor(for: .info)
            )
        }
        .padding(.horizontal, 24)
    }

    private func descriptor(for severity: LintSeverity) -> String {
        let count = hrdResults.filter { $0.severity == severity }.count
        return count == 0 ? "Clean" : "\(count) HRD"
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
                    .help("Surgically remove every Claudoscope hardening artifact.")
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
        case .notInstalled: return "lock.shield"
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
        case .notInstalled: return "Install Hardening Baseline"
        case .installedClean: return "Baseline is current"
        case .installedDrifted: return "Baseline has drifted"
        }
    }

    private var ctaSubtitle: String {
        switch ctaState {
        case .notInstalled:
            return "Adds Claudoscope's vendor-neutral baseline across deny rules, sandbox, hooks, autoMode, governance, and the security-awareness skill."
        case .installedClean:
            return "All hardening checks pass. Reinstall to refresh files from the bundled baseline."
        case .installedDrifted:
            return "\(hrdResults.count) hardening check(s) failing. Reinstall restores canonical files; per-rule fixes appear below."
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch ctaState {
        case .notInstalled:
            Button("Install Hardening Baseline") {
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

    // MARK: Per-layer summary

    private var layerSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LAYERS")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 24)

            HStack(spacing: 10) {
                ForEach(LayerCardSpec.all, id: \.id) { spec in
                    LayerCard(spec: spec, failingCount: failingCount(in: spec))
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private func failingCount(in spec: LayerCardSpec) -> Int {
        hrdResults.filter { spec.matches($0.checkId.rawValue) }.count
    }

    // MARK: Quick actions

    private var quickActionsRow: some View {
        HStack(spacing: 8) {
            Button {
                showTrustedSourcesSheet = true
            } label: {
                Label("Trusted Sources", systemImage: "globe.badge.chevron.backward")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            Button {
                showBackupsSheet = true
            } label: {
                Label("Backups", systemImage: "externaldrive.badge.timemachine")
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
                ForEach(hrdResults) { result in
                    DriftFixRow(result: result, onRescan: onRescan) {
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
            installer = HardeningInstaller(sessionStore: store)
        }
    }

    private func refreshMarker() async {
        let url = claudeDirURL.appendingPathComponent(HardeningInstaller.markerFileName)
        let info = MarkerInfo.load(from: url)
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

private struct DriftFixRow: View {
    let result: LintResult
    var onRescan: (() -> Void)?
    let onSelect: () -> Void

    @State private var fixApplied = false

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
            if fixApplied {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                    Text("Applied")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.green)
            } else if ConfigAutoFixer.canFix(result.checkId) {
                Button("Fix") {
                    let success = ConfigAutoFixer.apply(
                        checkId: result.checkId,
                        settingsPath: result.filePath
                    )
                    if success {
                        fixApplied = true
                        onRescan?()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
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

// MARK: - Layer card

private struct LayerCard: View {
    let spec: LayerCardSpec
    let failingCount: Int

    private var passing: Bool { failingCount == 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: passing ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(passing ? Color.green : Color.orange)
                Text(spec.label)
                    .font(Typography.bodyMedium)
                Spacer()
            }
            Text(spec.subtitle)
                .font(Typography.codeSmall)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            HStack(spacing: 4) {
                Text(passing ? "Pass" : "\(failingCount) failing")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(passing ? .green : .orange)
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
}

// MARK: - Layer spec

private struct LayerCardSpec {
    let id: String
    let label: String
    let subtitle: String
    let prefixes: [String]

    func matches(_ raw: String) -> Bool {
        prefixes.contains(where: raw.hasPrefix)
    }

    static let all: [LayerCardSpec] = [
        LayerCardSpec(
            id: "layer1",
            label: "Layer 1",
            subtitle: "Permissions + Sandbox",
            prefixes: ["HRD001", "HRD002"]
        ),
        LayerCardSpec(
            id: "layer2",
            label: "Layer 2",
            subtitle: "Hooks",
            prefixes: ["HRD003", "HRD004", "HRD005", "HRD006", "HRD007"]
        ),
        LayerCardSpec(
            id: "layer3",
            label: "Layer 3",
            subtitle: "AutoMode",
            prefixes: ["HRD008", "HRD009", "HRD012"]
        ),
        LayerCardSpec(
            id: "layer4",
            label: "Layer 4",
            subtitle: "Governance",
            prefixes: ["HRD010"]
        ),
        LayerCardSpec(
            id: "skill",
            label: "Skill",
            subtitle: "Awareness",
            prefixes: ["HRD011"]
        ),
    ]
}

// MARK: - CTA state + supporting types

private enum CTAState {
    case notInstalled
    case installedClean
    case installedDrifted
}

enum ActionKind {
    case install
    case reinstall
    case revert
    case uninstall

    var label: String {
        switch self {
        case .install: return "Installing..."
        case .reinstall: return "Reinstalling..."
        case .revert: return "Reverting..."
        case .uninstall: return "Uninstalling..."
        }
    }
}

struct ActionResult {
    let message: String
    let isError: Bool
}

// MARK: - Marker info

struct MarkerInfo {
    let installedAt: Date?
    let backupPath: URL?
    let layersApplied: [String]

    var installedAtDisplay: String {
        guard let installedAt else { return "(unknown date)" }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: installedAt)
    }

    static func load(from url: URL) -> MarkerInfo? {
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
        let layers = dict["layersApplied"] as? [String] ?? []

        return MarkerInfo(
            installedAt: date,
            backupPath: backup,
            layersApplied: layers
        )
    }
}
