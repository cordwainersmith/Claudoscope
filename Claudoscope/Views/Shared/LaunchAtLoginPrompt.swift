import AppKit

/// One-time, opt-in prompt asking whether Claudoscope should open at login.
/// Safe to call on every launch; it shows the alert at most once, ever.
@MainActor
enum LaunchAtLoginPrompt {
    static let promptedKey = "hasPromptedLaunchAtLogin"

    static func presentIfNeeded(service: LoginItemService) {
        let defaults = UserDefaults.standard

        // Already asked before -> never again.
        guard !defaults.bool(forKey: promptedKey) else { return }

        // Registration isn't possible for this build (unsigned/dev) -> don't prompt,
        // and don't burn the gate so a later installed build can still ask.
        guard !service.isUnavailable else { return }

        // Already enabled (e.g. set in System Settings) -> record and skip the dialog.
        guard !service.isEnabled else {
            defaults.set(true, forKey: promptedKey)
            return
        }

        // The user is now being asked: every exit path counts as "prompted".
        defer { defaults.set(true, forKey: promptedKey) }

        // Bring the menu bar agent forward so the modal takes focus, then restore
        // whatever policy we had (don't force .accessory and hide an open window's Dock icon).
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        defer { NSApp.setActivationPolicy(previousPolicy) }

        let alert = NSAlert()
        alert.messageText = "Open Claudoscope at login?"
        alert.informativeText = "Claudoscope can start automatically when you log in, so it's always in your menu bar. You can change this anytime in Settings."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open at Login") // .alertFirstButtonReturn (default / Return)
        alert.addButton(withTitle: "Not Now")       // .alertSecondButtonReturn (Esc)

        if alert.runModal() == .alertFirstButtonReturn {
            service.setEnabled(true)
        }
    }
}
