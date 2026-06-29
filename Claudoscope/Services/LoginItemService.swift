import Foundation
import ServiceManagement
import os

/// Wraps the system login-item registration for the main app via `SMAppService.mainApp`.
/// The system is the source of truth; `status` mirrors it so SwiftUI can observe changes.
@MainActor
@Observable
final class LoginItemService {
    private let logger = Logger(subsystem: "com.cordwainersmith.Claudoscope", category: "LoginItem")

    /// Stored mirror of the system's login-item status. Stored (not computed) so `@Observable`
    /// tracks it and we don't query the framework on every redraw.
    private(set) var status: SMAppService.Status

    init() {
        status = SMAppService.mainApp.status
    }

    var isEnabled: Bool { status == .enabled }
    var requiresApproval: Bool { status == .requiresApproval }
    /// True when registration is impossible for this build (e.g. an unsigned `swift run` with no app bundle).
    var isUnavailable: Bool { status == .notFound }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch let error as NSError {
            // Re-registering when already registered (or unregistering when already gone)
            // is a no-op, not a failure.
            let benign = (on && error.code == kSMErrorAlreadyRegistered)
                || (!on && error.code == kSMErrorJobNotFound)
            if !benign {
                logger.error("Login item \(on ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription)")
            }
        }
        refresh()
    }

    func openSystemLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
