import SwiftUI

// MARK: - Uninstall Sheet

/// Destructive confirmation sheet that removes routing stack artifacts.
/// Conservative by design: an agent file the user edited after install is
/// left in place and reported rather than overwritten. Optionally also
/// deletes all backup directories.
struct RoutingUninstallSheet: View {
    let installer: RoutingStackInstaller?
    let claudeDirURL: URL
    var onCompleted: (ActionResult) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .review
    @State private var errorMessage: String?
    @State private var deleteBackups: Bool = false
    @State private var backupSummary: BackupSummary = .empty
    @State private var report: RoutingUninstallReport?

    enum Phase {
        case review
        case running
        case success
        case error
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            switch phase {
            case .review:
                reviewBody
            case .running:
                runningBody
            case .success:
                successBody
            case .error:
                errorBody
            }

            Divider()

            footer
        }
        .frame(width: 540)
        .frame(minHeight: 460)
        .task {
            await loadBackupSummary()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "xmark.shield.fill")
                .font(.system(size: 18))
                .foregroundStyle(.red)
            Text("Uninstall Agent Routing Stack")
                .font(Typography.panelTitle)
            Spacer()
        }
        .padding(Spacing.lg)
    }

    // MARK: Review

    private var reviewBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("This removes routing stack artifacts. Agent files you've edited since install are kept in place and reported, never overwritten or deleted.")
                    .font(Typography.body)
                    .foregroundStyle(.secondary)

                section(title: "What will be removed") {
                    bullet("Installed agent files under ~/.claude/agents/ that match what was installed")
                    bullet("Orchestration policy block between BEGIN/END markers in ~/.claude/CLAUDE.md")
                    bullet("fallbackModel in settings.json (only if this stack set it and it hasn't changed)")
                    bullet("~/.claude/\(RoutingStackInstaller.markerFileName)")
                }

                if backupSummary.count > 0 {
                    section(title: "Backups") {
                        Toggle(isOn: $deleteBackups) {
                            Text("Also delete \(backupSummary.count) backup director\(backupSummary.count == 1 ? "y" : "ies") (\(backupSummary.formattedSize))")
                                .font(Typography.body)
                        }
                        .toggleStyle(.checkbox)
                        Text("Backups live under ~/.claude/.claudoscope-routing-backup-* and let Revert restore the pre-install state. Default: keep them.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(Spacing.lg)
        }
    }

    // MARK: Running

    private var runningBody: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView().controlSize(.large)
            Text("Removing routing stack...")
                .font(Typography.bodyMedium)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.xl)
    }

    // MARK: Success

    private var successBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.green)
                    Text("Routing stack removed")
                        .font(Typography.bodyMedium)
                }

                if let report {
                    if !report.removedFiles.isEmpty {
                        section(title: "Removed") {
                            ForEach(report.removedFiles, id: \.self) { bullet($0) }
                        }
                    }
                    if !report.keptUserEditedFiles.isEmpty {
                        section(title: "Kept (edited since install)") {
                            ForEach(report.keptUserEditedFiles, id: \.self) { bullet($0) }
                        }
                    }
                    Text("Policy block: \(report.policyBlockRemoved ? "removed" : "not present"). fallbackModel: \(report.fallbackModelRemoved ? "removed" : "left as is"). \(deleteBackups ? "All backup directories were deleted." : "Backup directories are preserved.")")
                        .font(Typography.body)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(Spacing.lg)
        }
    }

    // MARK: Error

    private var errorBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.red)
                Text("Uninstall failed")
                    .font(Typography.bodyMedium)
            }
            ScrollView {
                Text(errorMessage ?? "Unknown error")
                    .font(Typography.code)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.red.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: Radius.md))
            }
            .frame(maxHeight: 240)
        }
        .padding(Spacing.lg)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            switch phase {
            case .review:
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Uninstall") { runUninstall() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .keyboardShortcut(.defaultAction)
            case .running:
                Button("Cancel") { }
                    .disabled(true)
            case .success:
                Button("Close") {
                    onCompleted(ActionResult(message: "Agent routing stack removed.", isError: false))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            case .error:
                Button("Close") {
                    onCompleted(ActionResult(message: errorMessage ?? "Uninstall failed.", isError: true))
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Retry") { runUninstall() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.lg)
    }

    // MARK: Actions

    private func runUninstall() {
        guard let installer else {
            errorMessage = "Installer is not available."
            phase = .error
            return
        }
        phase = .running
        let alsoDeleteBackups = deleteBackups
        Task {
            do {
                let result = try await installer.uninstall(deleteBackups: alsoDeleteBackups)
                await MainActor.run {
                    self.report = result
                    self.phase = .success
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = String(describing: error)
                    self.phase = .error
                }
            }
        }
    }

    private func loadBackupSummary() async {
        let dirs = InstallerFileOps.backupDirectories(in: claudeDirURL, prefix: RoutingStackInstaller.backupPrefix)
        var total: Int64 = 0
        for url in dirs { total += InstallerFileOps.sizeOf(directory: url) }
        let summary = BackupSummary(count: dirs.count, totalBytes: total)
        await MainActor.run { self.backupSummary = summary }
    }

    // MARK: Building blocks

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
            content()
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\u{2022}")
                .font(Typography.body)
                .foregroundStyle(.tertiary)
            Text(text)
                .font(Typography.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
        .padding(.leading, 4)
    }
}
