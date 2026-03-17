import SwiftUI

// MARK: - Onboarding Window

final class OnboardingWindowController {
    static let shared = OnboardingWindowController()

    private var window: NSWindow?

    func show() {
        guard window == nil else { return }

        let contentView = OnboardingView {
            self.dismiss()
        }

        let hostingView = NSHostingView(rootView: contentView)

        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 0),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Claudoscope"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()
        window.makeKeyAndOrderFront(nil)

        // Show briefly in Dock so the window is visible
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        self.window = window
    }

    private func dismiss() {
        window?.close()
        window = nil
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

struct OnboardingView: View {
    let onDismiss: () -> Void
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var dontShowAgain = false

    private var menuBarImage: NSImage? {
        guard let url = Bundle.main.url(forResource: "menu-bar-icon", withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = false
        return img
    }

    var body: some View {
        VStack(spacing: 20) {
            // App icon
            if let nsImage = loadAppIcon() {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 56, height: 56)
            }

            Text("Claudoscope lives in your menu bar")
                .font(.system(size: 16, weight: .semibold))

            // Menu bar icon illustration
            HStack(spacing: 10) {
                Text("Look for this icon:")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                if let nsImage = menuBarImage {
                    Image(nsImage: nsImage)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 22, height: 22)
                        .padding(4)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.quaternary)
                        )
                }

                Text("in your menu bar")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            // Notch tip
            VStack(spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(Typography.body)
                        .foregroundStyle(.orange)

                    Text("If you can't see it, the icon might be hidden behind the notch. Hold **\u{2318} Cmd** and drag other menu bar icons to the left to make room.")
                        .font(Typography.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.orange.opacity(0.08))
                    .strokeBorder(Color.orange.opacity(0.15), lineWidth: 1)
            )

            Divider()

            // Don't show again + Got it
            HStack {
                Toggle("Show this at startup", isOn: Binding(
                    get: { !dontShowAgain },
                    set: { dontShowAgain = !$0 }
                ))
                    .toggleStyle(.checkbox)
                    .font(Typography.body)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Got it") {
                    hasSeenOnboarding = dontShowAgain
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}
