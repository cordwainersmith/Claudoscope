import Foundation

/// Owns Canon's per-machine opt-in state and drives the installer. Mirrors
/// `SessionNotificationService`: a Codable config persisted to UserDefaults with
/// `didSet`, injected into the SwiftUI environment.
@MainActor @Observable
final class CanonService {
    var config: CanonConfig {
        didSet { persist() }
    }

    /// The protocol version this app build ships. Used by the outdated-protocol
    /// check (CAN004) to compare against what's installed on disk.
    let bundledProtocolVersion = CanonArtifacts.protocolVersion

    private let installer = CanonInstaller()
    private static let defaultsKey = "canonConfig"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(CanonConfig.self, from: data) {
            self.config = decoded
        } else {
            self.config = .default
        }
    }

    func isOptedIn(_ projectId: String) -> Bool {
        config.optedInProjectIds.contains(projectId)
    }

    /// Install the artifacts into the project and record the opt-in. Opt-in is
    /// only recorded on a successful install.
    func enable(projectId: String, projectPath: String) async throws -> CanonInstallResult {
        let claudeDir = URL(fileURLWithPath: projectPath).appendingPathComponent(".claude")
        let result = try await installer.install(
            into: claudeDir,
            ruleText: CanonArtifacts.ruleFileText,
            seedText: CanonArtifacts.seedFileText
        )
        config.optedInProjectIds.insert(projectId)
        return result
    }

    /// Remove the protocol rule (records are kept) and clear the opt-in.
    func disable(projectId: String, projectPath: String) async throws {
        let claudeDir = URL(fileURLWithPath: projectPath).appendingPathComponent(".claude")
        try await installer.uninstall(from: claudeDir)
        config.optedInProjectIds.remove(projectId)
    }

    /// Clear the opt-in flag without touching the filesystem. Used when a
    /// project's repo path no longer exists, so there is nothing to uninstall
    /// but the stale opt-in should still be dropped.
    func forgetOptIn(_ projectId: String) {
        config.optedInProjectIds.remove(projectId)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
