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
    @State private var hotKeyService: GlobalHotKeyService
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
        let hotKeyService = GlobalHotKeyService()
        _hotKeyService = State(initialValue: hotKeyService)
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
        // And selects it in the dashboard if that window is open.
        sessionNotificationService.onSelectSession = { [weak store] projectId, sessionId in
            store?.requestedSelection = RequestedSelection(projectId: projectId, sessionId: sessionId)
        }
        // Jump shortcut: focus the oldest waiting agent's terminal, or open the
        // Fleet rail when nothing is waiting.
        hotKeyService.onTrigger = { [weak store, weak updateService] in
            guard let store else { return }
            if let first = store.attentionQueue.first, !first.summary.isCowork {
                TerminalFocuser.focus(matchingTitle: first.focusNeedle)
            } else {
                store.requestedRail = .fleet
                MainWindowController.shared.open(store: store, updateService: updateService)
            }
        }

        MainWindowController.shared.setUpdateService(updateService)
        MainWindowController.shared.setLoginItemService(loginItemService)
        MainWindowController.shared.setCostAlertService(costAlertService)
        MainWindowController.shared.setSessionNotificationService(sessionNotificationService)
        MainWindowController.shared.setCanonService(canonService)
        MainWindowController.shared.setMcpServerService(mcpServerService)
        MainWindowController.shared.setHotKeyService(hotKeyService)

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
                hasCostAlert: costAlertService.hasUnseen,
                monochrome: store.monochromeMenuBarIcon,
                pips: store.menuBarPips,
                waitingEscalated: store.fleetAttentionEscalated,
                hasFleetWarning: store.fleetHasWarning
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

/// Menu bar label: the app icon, alert dots, and one pip per live session so
/// "how many, and does any need me" reads without a number.
///
/// MenuBarExtra renders only Text and Image in its label; shapes are dropped
/// silently (the old count's capsule never drew). So the whole label is
/// composed with ImageRenderer into one NSImage and shown as an Image.
struct MenuBarIcon: View {
    var hasUpdate: Bool = false
    var hasCostAlert: Bool = false
    var monochrome: Bool = false
    /// Live sessions, attention first (see `MenuBarPip.pips(for:)`).
    var pips: [MenuBarPip] = []
    /// A wait went long or a waiting agent's cache is about to expire.
    var waitingEscalated: Bool = false
    /// A live agent ran with skipped permissions; red dot when no cost alert.
    var hasFleetWarning: Bool = false

    var body: some View {
        let key = MenuBarLabelKey(
            hasUpdate: hasUpdate, hasCostAlert: hasCostAlert, monochrome: monochrome,
            pips: pips, waitingEscalated: waitingEscalated, hasFleetWarning: hasFleetWarning
        )
        if let image = MenuBarLabelRenderer.image(for: key) {
            Image(nsImage: image)
                .renderingMode(monochrome ? .template : .original)
        } else {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
        }
    }
}

struct MenuBarLabelKey: Hashable {
    let hasUpdate: Bool
    let hasCostAlert: Bool
    let monochrome: Bool
    let pips: [MenuBarPip]
    let waitingEscalated: Bool
    let hasFleetWarning: Bool
}

@MainActor
enum MenuBarLabelRenderer {
    private static var cache: [MenuBarLabelKey: NSImage] = [:]

    static func image(for key: MenuBarLabelKey) -> NSImage? {
        if let cached = cache[key] { return cached }
        let resourceName = key.monochrome ? "menu-bar-icon-mono" : "menu-bar-icon"
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "png"),
              let base = NSImage(contentsOf: url) else { return nil }
        let renderer = ImageRenderer(content: MenuBarLabelContent(key: key, base: base))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = key.monochrome
        if cache.count > 64 { cache.removeAll() }
        cache[key] = image
        return image
    }
}

/// The label as drawn: icon with alert dot, then the pip cluster.
struct MenuBarLabelContent: View {
    let key: MenuBarLabelKey
    let base: NSImage

    private static let maxPips = 5

    /// Template images must be drawn in solid black so the system tints them.
    /// The color label has no appearance to adapt to, so its text is a mid
    /// gray that reads on both a light and a dark menu bar.
    private var ink: Color { key.monochrome ? .black : Color(red: 0.56, green: 0.56, blue: 0.58) }

    var body: some View {
        HStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: base)
                    .renderingMode(.original)
                if key.hasCostAlert || key.hasFleetWarning {
                    Circle()
                        .fill(key.monochrome ? Color.black : Color.red)
                        .frame(width: 6, height: 6)
                        .offset(x: 2, y: -2)
                } else if key.hasUpdate {
                    Circle()
                        .fill(key.monochrome ? Color.black : Color.orange)
                        .frame(width: 6, height: 6)
                        .offset(x: 2, y: -2)
                }
            }
            if !key.pips.isEmpty {
                HStack(spacing: 2.5) {
                    ForEach(Array(key.pips.prefix(Self.maxPips).enumerated()), id: \.offset) { _, pip in
                        pipView(pip)
                    }
                    if key.pips.count > Self.maxPips {
                        Text("+\(key.pips.count - Self.maxPips)")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(ink)
                    }
                }
                .padding(.trailing, 1)
            }
        }
        .padding(.trailing, 2)
    }

    @ViewBuilder
    private func pipView(_ pip: MenuBarPip) -> some View {
        switch pip {
        case .waiting:
            Rectangle()
                .fill(key.monochrome ? Color.black : (key.waitingEscalated ? Color.okabeVermillion : Color.okabeOrange))
                .frame(width: 5, height: 5)
                .rotationEffect(.degrees(45))
                .frame(width: 7, height: 7)
        case .working:
            Circle()
                .fill(key.monochrome ? Color.black : Color.okabeBlue)
                .frame(width: 5, height: 5)
                .frame(width: 7, height: 7)
        case .idle:
            Circle()
                .strokeBorder(key.monochrome ? Color.black.opacity(0.6) : Color.okabeGray, lineWidth: 1)
                .frame(width: 5, height: 5)
                .frame(width: 7, height: 7)
        }
    }
}

/// What one live session looks like in the menu bar. Order is the Fleet
/// attention order: anything waiting on the user first, then working, then idle.
enum MenuBarPip: Hashable {
    case waiting, working, idle

    static func pips(for agents: [FleetAgent]) -> [MenuBarPip] {
        let live = agents.filter { $0.isLive || $0.state == .working }
        return live.map { agent -> MenuBarPip in
            switch agent.state {
            case .blockedOnPermission, .waitingOnUser: return .waiting
            case .working: return .working
            case .idle, .failed, .done: return .idle
            }
        }
        .sorted { rank($0) < rank($1) }
    }

    private static func rank(_ pip: MenuBarPip) -> Int {
        switch pip {
        case .waiting: return 0
        case .working: return 1
        case .idle: return 2
        }
    }
}
