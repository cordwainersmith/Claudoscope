import AppKit
import Foundation
import UserNotifications

/// Owns cost-alert configuration, fired-state persistence, the intraday spend
/// ledger, and alert delivery (macOS notification + menu bar badge state).
/// Evaluation is driven by SessionStore at the end of recomputeAnalytics().
@MainActor @Observable
final class CostAlertService {

    var config: CostAlertConfig {
        didSet {
            guard config != oldValue else { return }
            persistConfig()
            if config.masterEnabled && !oldValue.masterEnabled {
                requestNotificationPermission()
            }
            if !config.masterEnabled && oldValue.masterEnabled {
                recentAlerts = []
                hasUnseen = false
            }
        }
    }

    /// Newest first, shown in the popover strip until dismissed.
    private(set) var recentAlerts: [CostAlertEvent] = []
    /// Drives the menu bar dot; cleared when the popover is opened.
    private(set) var hasUnseen = false
    private(set) var notificationsDenied = false

    var onOpenDashboard: (() -> Void)?

    @ObservationIgnored private var firedState: CostAlertFiredState
    @ObservationIgnored private var ledger = SpendLedger()
    @ObservationIgnored private let notificationDelegate = CostAlertNotificationDelegate()

    private static let configKey = "costAlertConfig"
    private static let firedStateKey = "costAlertFiredState"
    private static let recentAlertsCap = 5

    /// UNUserNotificationCenter traps in a non-bundled binary (swift run, SPM
    /// tests), so every notification path goes through this optional.
    private var notificationCenter: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier != nil ? UNUserNotificationCenter.current() : nil
    }

    var notificationsUnavailable: Bool { Bundle.main.bundleIdentifier == nil }

    init() {
        self.config = Self.loadConfig()
        var state = Self.loadFiredState()
        state.rollingLevel = 0
        self.firedState = state

        if let center = notificationCenter {
            notificationDelegate.onTap = { [weak self] in self?.onOpenDashboard?() }
            center.delegate = notificationDelegate
        }

        // Returning from System Settings reactivates the app; refresh so the
        // denied warning clears as soon as the user flips notifications on.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.config.masterEnabled else { return }
                self.refreshAuthorizationStatus()
            }
        }
    }

    func evaluate(snapshot: CostSnapshot, rebaselineLedger: Bool) {
        let now = Date()
        // Feed the ledger even while disabled so enabling mid-day starts with
        // a warm rolling window instead of an empty one.
        ledger.observe(
            totalCost: snapshot.cumulativeCost,
            totalTokens: snapshot.cumulativeTokens,
            at: now,
            rebaseline: rebaselineLedger
        )
        guard config.masterEnabled else { return }

        let window = ledger.windowTotals(minutes: config.rollingWindowMinutes, at: now)
        let (events, newState) = CostAlertEngine.evaluate(
            config: config,
            snapshot: snapshot,
            rollingCost: window.cost,
            rollingTokens: window.tokens,
            state: firedState
        )
        if newState != firedState {
            firedState = newState
            persistFiredState()
        }
        guard !events.isEmpty else { return }

        recentAlerts = Array((events.reversed() + recentAlerts).prefix(Self.recentAlertsCap))
        hasUnseen = true
        postNotifications(events)
    }

    func acknowledgeSeen() {
        hasUnseen = false
    }

    func dismissAlerts() {
        recentAlerts = []
        hasUnseen = false
    }

    func refreshAuthorizationStatus() {
        guard let center = notificationCenter else { return }
        center.getNotificationSettings { [weak self] settings in
            let denied = settings.authorizationStatus == .denied
            Task { @MainActor in self?.notificationsDenied = denied }
        }
    }

    /// Deep link to System Settings > Notifications, scrolled to this app.
    func openSystemNotificationSettings() {
        var urlString = "x-apple.systempreferences:com.apple.preference.notifications"
        if let bundleId = Bundle.main.bundleIdentifier {
            urlString += "?id=\(bundleId)"
        }
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Delivery

    private func requestNotificationPermission() {
        guard let center = notificationCenter else { return }
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in self?.notificationsDenied = !granted }
        }
    }

    private func postNotifications(_ events: [CostAlertEvent]) {
        guard let center = notificationCenter else { return }
        for event in events {
            let content = UNMutableNotificationContent()
            content.title = event.headline
            content.body = event.detail
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "costAlert-\(event.kind.rawValue)-\(event.scopeId)-\(event.level)",
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }

    // MARK: - Persistence

    private func persistConfig() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Self.configKey)
        }
    }

    private static func loadConfig() -> CostAlertConfig {
        guard let data = UserDefaults.standard.data(forKey: configKey),
              let decoded = try? JSONDecoder().decode(CostAlertConfig.self, from: data) else {
            return .default
        }
        return decoded
    }

    private func persistFiredState() {
        if let data = try? JSONEncoder().encode(firedState) {
            UserDefaults.standard.set(data, forKey: Self.firedStateKey)
        }
    }

    private static func loadFiredState() -> CostAlertFiredState {
        guard let data = UserDefaults.standard.data(forKey: firedStateKey),
              let decoded = try? JSONDecoder().decode(CostAlertFiredState.self, from: data) else {
            return CostAlertFiredState()
        }
        return decoded
    }
}

// MARK: - Notification Delegate

private final class CostAlertNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    var onTap: (@MainActor () -> Void)?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.notification.request.identifier.hasPrefix("costAlert-") {
            let onTap = onTap
            Task { @MainActor in onTap?() }
        }
        completionHandler()
    }
}
