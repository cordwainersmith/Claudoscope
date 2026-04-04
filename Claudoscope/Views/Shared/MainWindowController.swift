import SwiftUI

/// NSWindow subclass that reverts the app to accessory (no Dock icon) when closed.
final class PersistentWindow: NSWindow {
    override func close() {
        super.close()
        // Hide from Dock again when the full window is closed
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

/// Manages the main NSWindow directly, bypassing SwiftUI's Window scene limitations
final class MainWindowController {
    static let shared = MainWindowController()

    private var window: NSWindow?

    private var updateService: UpdateService?
    private var profileManager: ProfileManager?

    func setUpdateService(_ service: UpdateService) {
        self.updateService = service
    }

    func setProfileManager(_ manager: ProfileManager) {
        self.profileManager = manager
    }

    func open(store: SessionStore, updateService: UpdateService? = nil) {
        if let updateService { self.updateService = updateService }

        // If window exists and is visible, just bring it forward
        if let window, window.isVisible {
            DispatchQueue.main.async {
                self.showInDockSync()
                window.makeKeyAndOrderFront(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            return
        }

        guard let profileManager = self.profileManager else {
            assertionFailure("ProfileManager must be set before opening the main window")
            return
        }
        let contentView = FullWindowView()
            .environment(store)
            .environment(profileManager)
            .environment(self.updateService ?? UpdateService())
            .frame(minWidth: 900, minHeight: 600)

        let hostingView = NSHostingView(rootView: contentView)

        let window = PersistentWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Claudoscope"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("ClaudoscopeMainWindow")
        window.appearance = store.appearance.nsAppearance

        self.window = window

        // Defer showing in Dock and presenting the window to the next run
        // loop iteration so the MenuBarExtra popover finishes dismissing
        // first and won't revert the activation policy back to .accessory.
        DispatchQueue.main.async {
            self.showInDockSync()
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    func applyAppearance(_ appearance: AppAppearance) {
        window?.appearance = appearance.nsAppearance
    }

    private func showInDockSync() {
        NSApplication.shared.setActivationPolicy(.regular)

        if let iconURL = Bundle.main.url(forResource: "app-icon-rounded", withExtension: "png"),
           let iconImage = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = iconImage
        }
    }
}
