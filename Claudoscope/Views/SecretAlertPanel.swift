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

        // Position in top-right area of screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let panelSize = panel.frame.size
            let x = screenFrame.maxX - panelSize.width - 20
            let y = screenFrame.maxY - panelSize.height - 20
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

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
            HStack(spacing: 8) {
                Image(systemName: "shield.trianglebadge.exclamationmark")
                    .font(.system(size: 20))
                    .foregroundStyle(.red)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Secret Detected")
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
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(alert.maskedValue)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                }

                HStack(spacing: 6) {
                    Text("Session:")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(alert.sessionTitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
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
