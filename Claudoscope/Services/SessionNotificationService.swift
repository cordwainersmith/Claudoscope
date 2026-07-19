import AppKit
import Foundation
import UserNotifications

/// Owns session lifecycle notifications: configuration, the installed hooks, the
/// spool ingest path, a small session-title cache for labels, and delivery via
/// `UNUserNotificationCenter`. App-owned and driven by `SessionStore` (spool
/// events + titles), mirroring `CostAlertService`.
///
/// Two event-driven notifications, mirroring the classic session-notify.sh:
/// "Claude needs you" from the `Notification` hook (real blocks: permission,
/// plan, MCP; the passive idle prompt is dropped) and "Your turn" from the
/// `Stop` hook (fires once when a turn ends). No timers and no per-session
/// delivery state, so nothing can re-fire hours later.
///
/// Installs NO `UNUserNotificationCenter` delegate of its own: `CostAlertService`
/// owns the single shared delegate whose `willPresent` presents every
/// notification. Taps on our notifications are routed back here via
/// `CostAlertService.onSessionNotificationTap` -> `handleNotificationTap`, which
/// focuses the originating terminal (the classic session-notify.sh click action).
/// Construct this service AFTER `CostAlertService` so that delegate exists.
@MainActor @Observable
final class SessionNotificationService {

    enum Kind: String {
        case waiting     // a real block: permission / plan / MCP
        case yourTurn    // a turn finished (Stop hook)
    }

    var config: NotificationConfig {
        didSet {
            guard config != oldValue else { return }
            persistConfig()
        }
    }

    private(set) var notificationsDenied = false

    @ObservationIgnored private let claudeDir: URL
    @ObservationIgnored private let installer: NotificationHookInstaller
    /// Session id -> display title, so notifications can show "Title (folder)".
    /// A pure label cache; carries no delivery state.
    @ObservationIgnored private var sessionLabels: [String: String] = [:]

    private static let configKey = "sessionNotificationConfig"
    private static let eventTTL: TimeInterval = 120

    private var spoolDir: URL { claudeDir.appendingPathComponent(NotificationHookInstaller.spoolDirName) }

    /// `UNUserNotificationCenter` traps in a non-bundled binary (swift run, SPM
    /// tests), so every notification path goes through this optional.
    private var notificationCenter: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier != nil ? UNUserNotificationCenter.current() : nil
    }

    var notificationsUnavailable: Bool { Bundle.main.bundleIdentifier == nil }

    init(claudeDir: URL, setInstallInProgress: @escaping @Sendable @MainActor (Bool) -> Void) {
        self.claudeDir = claudeDir
        self.config = Self.loadConfig()
        self.installer = NotificationHookInstaller(claudeDir: claudeDir, setInstallInProgress: setInstallInProgress)

        // Live-only: clear any events queued while the app was down, without
        // notifying, so a resolved prompt from an hour ago never surfaces.
        drainSpool()

        // An app update can add the Stop hook to an already-enabled install;
        // reconcile on launch so both hooks are present without a manual toggle.
        if config.masterEnabled {
            Task { await installer.ensureHooks() }
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

    // MARK: - Enable / disable (drives hook install + permission)

    /// True when the user already has a `session-notify.sh` hook that would
    /// double-notify. The Settings UI uses this to confirm replacement.
    func hasConflictingHook() async -> Bool {
        await installer.detectExistingSessionNotify()
    }

    func enable() async {
        requestNotificationPermission()
        do {
            try await installer.install()
            config.masterEnabled = true
        } catch {
            NSLog("[Claudoscope] Notification hook install failed: %@", "\(error)")
            config.masterEnabled = false
        }
    }

    func disable() async {
        config.masterEnabled = false
        do {
            try await installer.uninstall()
        } catch {
            NSLog("[Claudoscope] Notification hook uninstall failed: %@", "\(error)")
        }
        sessionLabels.removeAll()
        drainSpool()
    }

    // MARK: - Ingest (called by SessionStore)

    /// A spool file appeared. Parse, route by hook event, deliver, then delete.
    /// Any failure (unreadable, garbage, stale) is a silent no-op; the file is
    /// still removed so it can never be reprocessed.
    ///
    /// Both signals are event-driven and fire once per event (a `Stop` per turn,
    /// a block `Notification` per block); the ~60s re-fire is only the idle
    /// prompt, which is dropped. So no per-session dedupe is needed and nothing
    /// can re-fire hours later.
    func handleSpoolFile(_ url: URL) {
        defer { try? FileManager.default.removeItem(at: url) }
        guard config.masterEnabled else { return }
        guard let data = try? Data(contentsOf: url),
              let event = SessionNotificationEngine.parseSpoolPayload(data) else { return }

        // Freshness guard (sleep/wake, backlog): ignore events older than the TTL.
        if let mtime = fileMTime(url), Date().timeIntervalSince(mtime) > Self.eventTTL { return }

        let projectId = event.transcriptPath.flatMap { Self.projectId(forTranscriptPath: $0) }
        guard shouldDeliver(projectId: projectId) else { return }
        let folder = Self.folderName(projectId: projectId, cwd: event.cwd)
        let label = Self.composeLabel(title: sessionLabels[event.sessionId], folder: folder, sessionId: event.sessionId)

        if event.hookEventName == "Stop" {
            guard config.notifyOnYourTurn else { return }
            postNotification(
                kind: .yourTurn,
                sessionId: event.sessionId,
                title: "Claude is ready",
                subtitle: label,
                body: "Your turn.",
                focusNeedle: folder
            )
        } else {
            // Notification hook: fire on real blocks, drop the passive idle prompt.
            if SessionNotificationEngine.isIdlePrompt(
                notificationType: event.notificationType, message: event.message
            ) { return }
            guard config.notifyOnBlocks else { return }
            postNotification(
                kind: .waiting,
                sessionId: event.sessionId,
                title: "Claude needs you",
                subtitle: label,
                body: event.message ?? "Waiting for your input.",
                focusNeedle: folder
            )
        }
    }

    /// A session notification was tapped: focus the terminal tab whose title
    /// contains the session's project folder (the classic session-notify.sh click
    /// action). Routed here from the shared notification-center delegate, which
    /// calls this off the main thread; `nonisolated` because it touches no
    /// main-actor state and `TerminalFocuser` does its own dispatching.
    nonisolated func handleNotificationTap(userInfo: [AnyHashable: Any]) {
        guard let needle = userInfo["focusNeedle"] as? String, !needle.isEmpty else { return }
        TerminalFocuser.focus(matchingTitle: needle)
    }

    /// Record a session's display title so notifications can show "Title (folder)".
    /// Subagents are skipped (their titles are UUIDs). A pure label cache with no
    /// delivery state.
    func noteActivity(sessionId: String, isSubagent: Bool, title: String) {
        guard config.masterEnabled, !isSubagent, !title.isEmpty else { return }
        sessionLabels[sessionId] = title
    }

    // MARK: - Delivery

    private func shouldDeliver(projectId: String?) -> Bool {
        guard config.masterEnabled else { return false }
        if let projectId, config.mutedProjectIds.contains(projectId) { return false }
        if config.isInQuietHours(Date()) { return false }
        return true
    }

    private func postNotification(kind: Kind, sessionId: String, title: String, subtitle: String?, body: String, focusNeedle: String) {
        guard let center = notificationCenter else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle, !subtitle.isEmpty { content.subtitle = subtitle }
        content.body = body
        content.sound = config.soundEnabled ? Self.sound(for: kind) : nil
        // Carried to the tap handler so clicking focuses the originating terminal.
        content.userInfo = ["focusNeedle": focusNeedle]
        // Stable identifier: a repeat for the same (kind, session) replaces the
        // existing banner in Notification Center rather than stacking.
        let request = UNNotificationRequest(
            identifier: "claudoscope-\(kind.rawValue)-\(sessionId)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    private static func sound(for kind: Kind) -> UNNotificationSound {
        switch kind {
        case .waiting: return UNNotificationSound(named: UNNotificationSoundName("Funk.aiff"))
        case .yourTurn: return UNNotificationSound(named: UNNotificationSoundName("Ping.aiff"))
        }
    }

    func requestNotificationPermission() {
        guard let center = notificationCenter else { return }
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in self?.notificationsDenied = !granted }
        }
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

    // MARK: - Spool housekeeping

    private func drainSpool() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: spoolDir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "json" { try? fm.removeItem(at: f) }
    }

    // MARK: - Labels

    /// The project/repo folder name for a session (same decoder the sidebar
    /// uses). Used both as the notification subtitle base (overlaid with a
    /// meaningful title as "Title (folder)" via `composeLabel`) and as the
    /// click-to-focus needle matched against terminal tab titles. Everything
    /// comes from the hook payload, so it reads the same across any terminal.
    nonisolated static func folderName(projectId: String?, cwd: String?) -> String {
        projectId.flatMap { $0.isEmpty ? nil : projectLabel(fromProjectId: $0) }
            ?? cwd.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0).lastPathComponent }
            ?? "a session"
    }

    /// "Title (folder)" when the session has a real title, else just the folder.
    /// Drops a title that is the 8-char session-id fallback or equals the folder.
    nonisolated static func composeLabel(title: String?, folder: String, sessionId: String) -> String {
        if let title, !title.isEmpty, title != String(sessionId.prefix(8)), title != folder {
            return "\(title) (\(folder))"
        }
        return folder
    }

    private func fileMTime(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Project directory id for a transcript path: the component right after
    /// "projects" (mirrors `SessionStore.projectId(for:)`).
    nonisolated static func projectId(forTranscriptPath path: String) -> String? {
        let comps = URL(fileURLWithPath: path).pathComponents
        if let idx = comps.lastIndex(of: "projects"), idx + 1 < comps.count {
            return comps[idx + 1]
        }
        return nil
    }

    /// Human folder name for an encoded project id, via the app's shared decoder
    /// (correctly rejoins hyphenated folder names like "fix-okta-callback-race").
    nonisolated static func projectLabel(fromProjectId id: String) -> String {
        decodeProjectName(id)
    }

    // MARK: - Persistence

    private func persistConfig() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Self.configKey)
        }
    }

    private static func loadConfig() -> NotificationConfig {
        guard let data = UserDefaults.standard.data(forKey: configKey),
              let decoded = try? JSONDecoder().decode(NotificationConfig.self, from: data) else {
            return .default
        }
        return decoded
    }
}
