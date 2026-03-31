import SwiftUI
import AppKit

final class SecretAlertController {
    static let shared = SecretAlertController()

    private var window: NSWindow?
    private var autoDismissTimer: Timer?

    func show(alert: SecretAlert, onView: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        dismiss()

        let contentView = SecretAlertView(
            alert: alert,
            onView: {
                onView()
                self.dismiss()
            },
            onDismiss: {
                onDismiss()
                self.dismiss()
            }
        )

        let hostingView = NSHostingView(rootView: contentView)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 0),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Security Alert"
        panel.contentView = hostingView
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false

        panel.center()

        panel.makeKeyAndOrderFront(nil)
        self.window = panel

        // Auto-dismiss after 15 seconds
        autoDismissTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                onDismiss()
                self?.dismiss()
            }
        }
    }

    func dismiss() {
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil
        window?.close()
        window = nil
    }
}

private struct SecretAlertView: View {
    let alert: SecretAlert
    let onView: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                if let url = Bundle.main.url(forResource: "app-icon-rounded", withExtension: "png"),
                   let nsImage = NSImage(contentsOf: url) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .frame(width: 32, height: 32)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude Code Secret Detected")
                        .font(Typography.sectionTitle)
                    Text(alert.patternName)
                        .font(Typography.body)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Value:")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(alert.maskedValue)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                }

                HStack(spacing: 6) {
                    Text("Session:")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(alert.sessionTitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                if alert.isSubagent {
                    HStack(spacing: 6) {
                        Text("Source:")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text("Subagent task")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.red.opacity(0.06))
                    .strokeBorder(Color.red.opacity(0.15), lineWidth: 1)
            )

            HStack {
                Button("Dismiss") {
                    onDismiss()
                }

                Spacer()

                Button("View in Config Health") {
                    onView()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
