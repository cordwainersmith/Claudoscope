import SwiftUI

@main
struct ClaudoscopeApp: App {
    @State private var store: SessionStore
    @State private var updateService: UpdateService
    @State private var loginItemService: LoginItemService
    @State private var costAlertService: CostAlertService
    @State private var sessionNotificationService: SessionNotificationService
    @State private var canonService: CanonService
    @State private var mcpServerService: McpServerService
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    init() {
        let store = SessionStore()
        let updateService = UpdateService()
        let loginItemService = LoginItemService()
        let costAlertService = CostAlertService()
        // Constructed AFTER costAlertService so its notification-center delegate
        // is already set (this service deliberately installs none, relying on it).
        let sessionNotificationService = SessionNotificationService(
            claudeDir: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude"),
            setInstallInProgress: { [weak store] value in store?.setInstallInProgress(value) }
        )
        let canonService = CanonService()
        let mcpServerService = McpServerService()
        _store = State(initialValue: store)
        _updateService = State(initialValue: updateService)
        _loginItemService = State(initialValue: loginItemService)
        _costAlertService = State(initialValue: costAlertService)
        _sessionNotificationService = State(initialValue: sessionNotificationService)
        _canonService = State(initialValue: canonService)
        _mcpServerService = State(initialValue: mcpServerService)

        mcpServerService.attach(store: store, canonService: canonService)
        Task { await mcpServerService.startIfEnabled() }

        store.costAlertService = costAlertService
        store.sessionNotificationService = sessionNotificationService
        store.canonService = canonService
        costAlertService.onOpenDashboard = { [weak store] in
            guard let store else { return }
            MainWindowController.shared.open(store: store)
        }
        // Tapping a session notification focuses the terminal running that session.
        costAlertService.onSessionNotificationTap = { [weak sessionNotificationService] userInfo in
            sessionNotificationService?.handleNotificationTap(userInfo: userInfo)
        }

        MainWindowController.shared.setUpdateService(updateService)
        MainWindowController.shared.setLoginItemService(loginItemService)
        MainWindowController.shared.setCostAlertService(costAlertService)
        MainWindowController.shared.setSessionNotificationService(sessionNotificationService)
        MainWindowController.shared.setCanonService(canonService)
        MainWindowController.shared.setMcpServerService(mcpServerService)

        store.onSecretAlert = { [weak store] alert in
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

        // First-run flow: show onboarding for new users, then (once) ask about launching
        // at login. Already-onboarded users get the login prompt directly.
        let onboarded = UserDefaults.standard.bool(forKey: "hasSeenOnboarding")
        let needsLoginPrompt = !UserDefaults.standard.bool(forKey: LaunchAtLoginPrompt.promptedKey)

        if !onboarded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                OnboardingWindowController.shared.show {
                    if needsLoginPrompt {
                        LaunchAtLoginPrompt.presentIfNeeded(service: loginItemService)
                    }
                }
            }
        } else if needsLoginPrompt {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                LaunchAtLoginPrompt.presentIfNeeded(service: loginItemService)
            }
        }
    }

    var body: some Scene {
        // Menu bar popover (always present)
        MenuBarExtra {
            MenuBarPopoverContent()
                .environment(store)
                .environment(updateService)
                .environment(loginItemService)
                .environment(costAlertService)
                .environment(sessionNotificationService)
                .background {
                    UpdateTriggerView()
                        .environment(updateService)
                }
        } label: {
            MenuBarIcon(
                hasUpdate: updateService.updateAvailable != nil,
                hasCostAlert: costAlertService.hasUnseen
            )
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

        Window("About Claudoscope", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 340, height: 260)
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
                // Rollback safety: track successful launches and clean up .bak after 2
                let bakURL = Bundle.main.bundleURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(Bundle.main.bundleURL.lastPathComponent + ".bak")
                if FileManager.default.fileExists(atPath: bakURL.path) {
                    let launchCountKey = "successfulLaunchCount"
                    let count = UserDefaults.standard.integer(forKey: launchCountKey) + 1
                    if count >= 2 {
                        try? FileManager.default.removeItem(at: bakURL)
                        UserDefaults.standard.set(0, forKey: launchCountKey)
                    } else {
                        UserDefaults.standard.set(count, forKey: launchCountKey)
                    }
                }

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
    var hasCostAlert: Bool = false

    var body: some View {
        if let url = Bundle.main.url(forResource: "menu-bar-icon", withExtension: "png"),
           let nsImage = NSImage(contentsOf: url) {
            nsImage.isTemplate = false
            return AnyView(
                ZStack(alignment: .topTrailing) {
                    Image(nsImage: nsImage)
                        .renderingMode(.original)
                    if hasCostAlert {
                        Circle()
                            .fill(.red)
                            .frame(width: 6, height: 6)
                            .offset(x: 2, y: -2)
                    } else if hasUpdate {
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
