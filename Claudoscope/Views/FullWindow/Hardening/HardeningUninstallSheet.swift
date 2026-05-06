import SwiftUI

// MARK: - Uninstall Sheet

/// Destructive confirmation sheet that surgically removes every Claudoscope
/// hardening artifact. Optionally also deletes all backup directories.
struct HardeningUninstallSheet: View {
    let installer: HardeningInstaller?
    let claudeDirURL: URL
    var onCompleted: (ActionResult) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .review
    @State private var errorMessage: String?
    @State private var deleteBackups: Bool = false
    @State private var backupSummary: BackupSummary = .empty

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
            Text("Uninstall Hardening Baseline")
                .font(Typography.panelTitle)
            Spacer()
        }
        .padding(Spacing.lg)
    }

    // MARK: Review

    private var reviewBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("This removes every Claudoscope hardening artifact regardless of marker state. User-authored hooks, skills, and unrelated settings.json entries are left untouched.")
                    .font(Typography.body)
                    .foregroundStyle(.secondary)

                section(title: "What will be removed") {
                    bullet("Bundled permissions.deny entries from settings.json")
                    bullet("Bundled sandbox baseline entries (filesystem + network) from settings.json")
                    bullet("All claudoscope-*.sh hook scripts under ~/.claude/hooks/")
                    bullet("Hook registrations in settings.json that target claudoscope-*.sh")
                    bullet("autoMode block in settings.json (only if byte-equal to baseline)")
                    bullet("Governance block between BEGIN/END markers in ~/.claude/CLAUDE.md")
                    bullet("~/.claude/skills/claudoscope-security-awareness.md")
                    bullet("~/.claude/\(HardeningInstaller.markerFileName)")
                }

                if backupSummary.count > 0 {
                    section(title: "Backups") {
                        Toggle(isOn: $deleteBackups) {
                            Text("Also delete \(backupSummary.count) backup director\(backupSummary.count == 1 ? "y" : "ies") (\(backupSummary.formattedSize))")
                                .font(Typography.body)
                        }
                        .toggleStyle(.checkbox)
                        Text("Backups live under ~/.claude/.claudoscope-hardening-backup-* and let Revert restore the pre-install state. Default: keep them.")
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
            Text("Removing baseline...")
                .font(Typography.bodyMedium)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.xl)
    }

    // MARK: Success

    private var successBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.green)
                Text("Hardening baseline removed")
                    .font(Typography.bodyMedium)
            }
            Text("settings.json and CLAUDE.md have been cleaned up. \(deleteBackups ? "All backup directories were deleted." : "Backup directories are preserved.")")
                .font(Typography.body)
                .foregroundStyle(.secondary)
        }
        .padding(Spacing.lg)
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
                    onCompleted(ActionResult(message: "Hardening baseline removed.", isError: false))
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
                try await installer.uninstall(deleteBackups: alsoDeleteBackups)
                await MainActor.run {
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
        let summary = HardeningBackupListing.summarize(claudeDirURL: claudeDirURL)
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

// MARK: - Backup summary helpers (shared with HardeningBackupsSheet)

struct BackupSummary {
    let count: Int
    let totalBytes: Int64

    static let empty = BackupSummary(count: 0, totalBytes: 0)

    var formattedSize: String {
        let bcf = ByteCountFormatter()
        bcf.allowedUnits = [.useKB, .useMB, .useGB]
        bcf.countStyle = .file
        return bcf.string(fromByteCount: totalBytes)
    }
}

enum HardeningBackupListing {
    static func directories(in claudeDirURL: URL) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: claudeDirURL, includingPropertiesForKeys: nil) else {
            return []
        }
        return entries
            .filter { $0.lastPathComponent.hasPrefix(".claudoscope-hardening-backup-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func summarize(claudeDirURL: URL) -> BackupSummary {
        let dirs = directories(in: claudeDirURL)
        var total: Int64 = 0
        for url in dirs {
            total += sizeOf(directory: url)
        }
        return BackupSummary(count: dirs.count, totalBytes: total)
    }

    static func sizeOf(directory: URL) -> Int64 {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isRegularFile == true {
                let size = values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0
                total += Int64(size)
            }
        }
        return total
    }
}
