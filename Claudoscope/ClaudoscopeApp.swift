import SwiftUI

@main
struct ClaudoscopeApp: App {
    @State private var workspaceManager: WorkspaceManager
    @State private var store: SessionStore
    @State private var updateService: UpdateService
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    @MainActor init() {
        let workspaceManager = WorkspaceManager()
        let store = SessionStore(workspaceManager: workspaceManager)
        let updateService = UpdateService()
        _workspaceManager = State(initialValue: workspaceManager)
        _store = State(initialValue: store)
        _updateService = State(initialValue: updateService)

        MainWindowController.shared.setUpdateService(updateService)
        MainWindowController.shared.setWorkspaceManager(workspaceManager)

        store.onSecretAlert = { [weak store] (alert: SecretAlert) in
            guard let store else { return }
            SecretAlertController.shared.show(
                alert: alert,
                onView: {
                    MainWindowController.shared.open(store: store)
                    store.activeSecretAlert = nil
                },
                onDismiss: {
                    store.activeSecretAlert = nil
                }
            )
        }

        if !UserDefaults.standard.bool(forKey: "hasSeenOnboarding") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                OnboardingWindowController.shared.show()
            }
        }
    }

    var body: some Scene {
        // Menu bar popover (always present)
        MenuBarExtra {
            MenuBarPopoverContent()
                .environment(store)
                .environment(workspaceManager)
                .environment(updateService)
                .background {
                    UpdateTriggerView()
                        .environment(updateService)
                }
        } label: {
            MenuBarIcon(hasUpdate: updateService.updateAvailable != nil)
        }
        .menuBarExtraStyle(.window)

        Window("Update Available", id: "update-available") {
            UpdateAvailableWindowContent()
                .environment(updateService)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 400, height: 450)

        Window("Claudoscope Updated", id: "whats-new") {
            WhatsNewWindowContent()
                .environment(updateService)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 440, height: 450)
    }

}

// MARK: - Update Trigger View

/// Zero-size view embedded in MenuBarExtra to access openWindow environment action.
private struct UpdateTriggerView: View {
    @Environment(UpdateService.self) private var updateService
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task {
                // Show "What's New" if we just updated (runs once)
                if let info = updateService.consumeJustUpdatedInfo() {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    updateService.whatsNewInfo = info
                    openWindow(id: "whats-new")
                }

                // Auto-check shows popup when update found
                updateService.onUpdateFound = { _ in
                    openWindow(id: "update-available")
                }

                // Allow Settings (NSHostingView) to open the What's New window
                updateService.onOpenWhatsNew = {
                    openWindow(id: "whats-new")
                }

                updateService.startPeriodicChecks()
            }
    }
}

/// Loads the custom menu bar icon from bundle resources
struct MenuBarIcon: View {
    var hasUpdate: Bool = false

    var body: some View {
        if let url = Bundle.main.url(forResource: "menu-bar-icon", withExtension: "png"),
           let nsImage = NSImage(contentsOf: url) {
            nsImage.isTemplate = false
            return AnyView(
                ZStack(alignment: .topTrailing) {
                    Image(nsImage: nsImage)
                        .renderingMode(.original)
                    if hasUpdate {
                        Circle()
                            .fill(.orange)
                            .frame(width: 6, height: 6)
                            .offset(x: 2, y: -2)
                    }
                }
            )
        } else {
            return AnyView(Image(systemName: "chevron.left.forwardslash.chevron.right"))
        }
    }
}
