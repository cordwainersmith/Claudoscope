import SwiftUI

// MARK: - Backups Sheet

/// List of `~/.claude/.claudoscope-hardening-backup-*` directories with size,
/// timestamp, restore (only enabled for the marker-current backup), and delete
/// per row. If more than 5 backups exist, surfaces a Prune to last 5 button.
struct HardeningBackupsSheet: View {
    let claudeDirURL: URL
    let installer: HardeningInstaller?
    var onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var backups: [BackupRow] = []
    @State private var markerBackupPath: String?
    @State private var workingMessage: String?
    @State private var errorMessage: String?
    @State private var pendingDeletion: BackupRow?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 600)
        .frame(minHeight: 460)
        .task { reload() }
        .alert(
            "Delete this backup?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
            Button("Delete", role: .destructive) {
                if let target = pendingDeletion {
                    delete(target)
                }
                pendingDeletion = nil
            }
        } message: {
            Text(pendingDeletion?.url.lastPathComponent ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.badge.timemachine")
                .font(.system(size: 18))
                .foregroundStyle(Color.accentColor)
            Text("Backups")
                .font(Typography.panelTitle)
            Spacer()
            Button {
                reload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Refresh")
        }
        .padding(Spacing.lg)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Backups are written before each install. Restore only matches this install's marker; older backups must be inspected manually.")
                    .font(Typography.body)
                    .foregroundStyle(.secondary)

                if backups.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "tray")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                        Text("No backup directories found.")
                            .font(Typography.body)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
                } else {
                    VStack(spacing: 6) {
                        ForEach(backups, id: \.url) { backup in
                            BackupRowView(
                                backup: backup,
                                isMarkerBackup: matchesMarker(backup),
                                onRestore: { restore(backup) },
                                onDelete: { pendingDeletion = backup }
                            )
                        }
                    }
                }

                if backups.count > 5 {
                    HStack {
                        Spacer()
                        Button("Prune to last 5") {
                            pruneToLastFive()
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if let workingMessage {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(workingMessage)
                            .font(Typography.body)
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(Typography.body)
                        .foregroundStyle(.red)
                }
            }
            .padding(Spacing.lg)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(Spacing.lg)
    }

    // MARK: Helpers

    private func reload() {
        let dirs = HardeningBackupListing.directories(in: claudeDirURL)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd-HHmmss"
        dateFormatter.timeZone = TimeZone(identifier: "UTC")
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        var rows: [BackupRow] = []
        for url in dirs {
            let timestamp = url.lastPathComponent
                .replacingOccurrences(of: ".claudoscope-hardening-backup-", with: "")
            let date = dateFormatter.date(from: timestamp)
            let size = HardeningBackupListing.sizeOf(directory: url)
            rows.append(BackupRow(url: url, timestamp: timestamp, date: date, sizeBytes: size))
        }
        rows.sort { ($0.date ?? Date.distantPast) > ($1.date ?? Date.distantPast) }
        self.backups = rows

        // Read the marker (if any) to surface which backup is "current"
        let markerURL = claudeDirURL.appendingPathComponent(HardeningInstaller.markerFileName)
        if let data = try? Data(contentsOf: markerURL),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            self.markerBackupPath = dict["backupPath"] as? String
        } else {
            self.markerBackupPath = nil
        }
    }

    private func matchesMarker(_ backup: BackupRow) -> Bool {
        guard let markerBackupPath else { return false }
        return URL(fileURLWithPath: markerBackupPath).standardizedFileURL == backup.url.standardizedFileURL
    }

    private func restore(_ backup: BackupRow) {
        guard let installer else {
            errorMessage = "Installer is not available."
            return
        }
        guard matchesMarker(backup) else {
            errorMessage = "Restore is only available for the backup that matches the current install marker."
            return
        }
        workingMessage = "Restoring \(backup.url.lastPathComponent)..."
        errorMessage = nil
        Task {
            do {
                try await installer.revert()
                await MainActor.run {
                    workingMessage = nil
                    onChanged()
                    reload()
                }
            } catch {
                await MainActor.run {
                    workingMessage = nil
                    errorMessage = String(describing: error)
                }
            }
        }
    }

    private func delete(_ backup: BackupRow) {
        let fm = FileManager.default
        do {
            try fm.removeItem(at: backup.url)
            errorMessage = nil
            onChanged()
            reload()
        } catch {
            errorMessage = "Failed to delete \(backup.url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func pruneToLastFive() {
        // Backups are sorted newest first; the rest are stale
        let stale = Array(backups.dropFirst(5))
        guard !stale.isEmpty else { return }
        let fm = FileManager.default
        var failures: [String] = []
        for row in stale {
            do {
                try fm.removeItem(at: row.url)
            } catch {
                failures.append(row.url.lastPathComponent)
            }
        }
        if failures.isEmpty {
            errorMessage = nil
        } else {
            errorMessage = "Failed to remove: \(failures.joined(separator: ", "))"
        }
        onChanged()
        reload()
    }
}

// MARK: - Row model + view

struct BackupRow {
    let url: URL
    let timestamp: String
    let date: Date?
    let sizeBytes: Int64
}

private struct BackupRowView: View {
    let backup: BackupRow
    let isMarkerBackup: Bool
    let onRestore: () -> Void
    let onDelete: () -> Void

    private var displayDate: String {
        if let date = backup.date {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            return f.string(from: date)
        }
        return backup.timestamp
    }

    private var displaySize: String {
        let bcf = ByteCountFormatter()
        bcf.allowedUnits = [.useKB, .useMB, .useGB]
        bcf.countStyle = .file
        return bcf.string(fromByteCount: backup.sizeBytes)
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(displayDate)
                        .font(Typography.bodyMedium)
                    if isMarkerBackup {
                        Text("CURRENT")
                            .font(Typography.micro)
                            .foregroundStyle(.green)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.green.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
                HStack(spacing: 8) {
                    Text(backup.url.lastPathComponent)
                        .font(Typography.codeSmall)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Text("\u{00B7}")
                        .font(Typography.codeSmall)
                        .foregroundStyle(.tertiary)
                    Text(displaySize)
                        .font(Typography.codeSmall)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Restore") {
                onRestore()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!isMarkerBackup)
            .help(isMarkerBackup
                ? "Restore from this backup (matches the current marker)."
                : "Restore is only available for the backup that matches the current install marker.")

            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.red)
            .help("Delete this backup")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }
}
