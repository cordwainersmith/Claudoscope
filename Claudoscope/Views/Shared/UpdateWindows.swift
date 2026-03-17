import SwiftUI

// MARK: - Update Available Window

final class UpdateWindowController {
    static let shared = UpdateWindowController()

    private var window: NSWindow?

    func showUpdateAvailable(_ update: UpdateService.UpdateInfo, updateService: UpdateService) {
        dismiss()

        let contentView = UpdateAvailableView(
            update: update,
            updateService: updateService,
            onDismiss: { self.dismiss() },
            onSkip: {
                updateService.skipVersion(update.version)
                self.dismiss()
            }
        )

        let hostingView = NSHostingView(rootView: contentView)

        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 0),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Update Available"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()
        window.makeKeyAndOrderFront(nil)

        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        self.window = window
    }

    func showWhatsNew(version: String, releaseNotes: String?) {
        dismiss()

        let contentView = WhatsNewView(
            version: version,
            releaseNotes: releaseNotes,
            onDismiss: { self.dismiss() }
        )

        let hostingView = NSHostingView(rootView: contentView)

        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 0),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Claudoscope Updated"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()
        window.makeKeyAndOrderFront(nil)

        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        self.window = window
    }

    func dismiss() {
        let dismissingWindow = window
        window?.close()
        window = nil
        // Only revert to accessory if no other app windows are visible
        let hasOtherVisibleWindow = NSApp.windows.contains { w in
            w !== dismissingWindow && w.isVisible && w.level == .normal
        }
        if !hasOtherVisibleWindow {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }
}

struct UpdateAvailableView: View {
    let update: UpdateService.UpdateInfo
    let updateService: UpdateService
    let onDismiss: () -> Void
    var onSkip: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            if let nsImage = loadAppIcon() {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 48, height: 48)
            }

            VStack(spacing: 4) {
                Text("Claudoscope \(update.version) is available")
                    .font(.system(size: 15, weight: .semibold))

                Text("You're currently on version \(updateService.currentVersion)")
                    .font(Typography.body)
                    .foregroundStyle(.secondary)
            }

            if let notes = update.releaseNotes, !notes.isEmpty {
                ScrollView {
                    Text(notes)
                        .font(Typography.body)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .frame(maxHeight: 160)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(AnyShapeStyle(.quaternary))
                )
            }

            VStack(spacing: 8) {
                HStack {
                    Button("Later") {
                        updateService.updateAvailable = nil
                        onDismiss()
                    }

                    Spacer()

                    if updateService.isDownloading {
                        ProgressView(value: updateService.downloadProgress)
                            .frame(width: 80)
                        Text("\(Int(updateService.downloadProgress * 100))%")
                            .font(Typography.code)
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Download and Install") {
                            updateService.downloadAndInstall()
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }

                if !updateService.isDownloading {
                    HStack {
                        Button("Skip This Version") {
                            updateService.updateAvailable = nil
                            onSkip?()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 400)
    }
}

struct WhatsNewView: View {
    let version: String
    let releaseNotes: String?
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            if let nsImage = loadAppIcon() {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 48, height: 48)
            }

            VStack(spacing: 4) {
                Text("Updated to Claudoscope \(version)")
                    .font(.system(size: 15, weight: .semibold))

                Text("The update was installed successfully.")
                    .font(Typography.body)
                    .foregroundStyle(.secondary)
            }

            if let notes = releaseNotes, !notes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What's New")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)

                    ScrollView {
                        Text(notes)
                            .font(Typography.body)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .frame(maxHeight: 160)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(AnyShapeStyle(.quaternary))
                    )
                }
            }

            HStack {
                Spacer()
                Button("OK") {
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 400)
    }
}
