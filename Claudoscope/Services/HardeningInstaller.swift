import Foundation
import CryptoKit

// MARK: - Public Types

struct HardeningInstallOptions: Sendable {
    let layer1Permissions: Bool
    let layer1Sandbox: Bool
    let layer2Hooks: Bool
    let layer3AutoMode: Bool
    let layer4Governance: Bool
    let skill: Bool

    init(
        layer1Permissions: Bool = true,
        layer1Sandbox: Bool = true,
        layer2Hooks: Bool = true,
        layer3AutoMode: Bool = true,
        layer4Governance: Bool = true,
        skill: Bool = true
    ) {
        self.layer1Permissions = layer1Permissions
        self.layer1Sandbox = layer1Sandbox
        self.layer2Hooks = layer2Hooks
        self.layer3AutoMode = layer3AutoMode
        self.layer4Governance = layer4Governance
        self.skill = skill
    }
}

enum HardeningInstallError: Error, CustomStringConvertible {
    case bundleResourceMissing(String)
    case checksumMismatch(String)
    case malformedSettingsJson
    case noMarkerForRevert
    case io(String)

    var description: String {
        switch self {
        case .bundleResourceMissing(let name):
            return "Bundled hardening resource missing: \(name)"
        case .checksumMismatch(let name):
            return "Bundled file checksum mismatch (corrupted bundle): \(name)"
        case .malformedSettingsJson:
            return "~/.claude/settings.json is not valid JSON or has the wrong shape; aborting to preserve user data."
        case .noMarkerForRevert:
            return "No install marker found at ~/.claude/.claudoscope-hardening-installed. Use Uninstall to surgically remove instead."
        case .io(let detail):
            return "Filesystem error: \(detail)"
        }
    }
}

struct HardeningInstallResult: Sendable {
    let installedAt: Date
    let backupPath: URL
    let layersApplied: [String]
    let warnings: [String]
}

// MARK: - HardeningInstaller

/// Orchestrates installation, revert, and uninstall of the Claudoscope hardening
/// baseline against `~/.claude/`. Mirrors `install.sh` semantics in pure Swift,
/// against bundled resources under `Resources/HardeningBaseline/`.
///
/// All filesystem mutations go through atomic write helpers
/// (`replaceItemAt`) so partial states are not visible to FSEvents subscribers.
/// Settings.json is read once, mutated in memory across all selected layers,
/// then written exactly once.
actor HardeningInstaller {

    // MARK: Configuration

    private let claudeDir: URL
    private let bundleSubdirectory: String
    private let sessionStore: SessionStore

    /// The seven hook script filenames bundled under
    /// `Resources/HardeningBaseline/layer2-hooks/`. Order matches the registration
    /// matrix; basename comparison is used during uninstall to recognise our
    /// hook entries vs. user-authored ones.
    static let bundledHookScripts: [String] = [
        "claudoscope-protect-file.sh",
        "claudoscope-validate-commands.sh",
        "claudoscope-check-public-repo.sh",
        "claudoscope-flag-proprietary-files.sh",
        "claudoscope-check-package-age.sh",
        "claudoscope-check-git-reset-hard.sh",
        "claudoscope-scan-for-credentials.sh",
    ]

    static let bundledSkillFile: String = "claudoscope-security-awareness.md"

    static let governanceBeginMarker: String = "<!-- BEGIN: claudoscope-hardening -->"
    static let governanceEndMarker: String = "<!-- END: claudoscope-hardening -->"
    static let markerFileName: String = ".claudoscope-hardening-installed"

    // MARK: Init

    init(
        sessionStore: SessionStore,
        claudeDir: URL? = nil,
        bundleSubdirectory: String = "HardeningBaseline"
    ) {
        self.sessionStore = sessionStore
        self.claudeDir = claudeDir
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        self.bundleSubdirectory = bundleSubdirectory
    }

    // MARK: - Public API

    /// Install the hardening baseline.
    ///
    /// Sets `installInProgress = true` for the duration so FSEvents-driven lint
    /// reloads don't fire against a half-written settings.json. Reads
    /// settings.json once into a single dict, applies all selected layers,
    /// writes once atomically. Hook scripts and the skill stage to a `.staging-*`
    /// directory, are SHA-256-verified against bundled sidecars, then atomically
    /// renamed into place. CLAUDE.md is read-modify-written once. Marker file is
    /// written only on first install (preserves the original `backupPath` for
    /// later revert).
    func install(options: HardeningInstallOptions) async throws -> HardeningInstallResult {
        await markInstallStart()
        defer { Task { await markInstallEnd() } }

        let warnings: [String] = []
        var layersApplied: [String] = []
        let installStart = Date()

        // 1. Backup
        let backupDir = try createBackup()

        // 2. Read settings.json once (or start from empty dict)
        let settingsURL = claudeDir.appendingPathComponent("settings.json")
        var settings = try readSettingsJSON(at: settingsURL)

        // 3. Layer 1 permissions
        if options.layer1Permissions {
            let permissionsBundle = try loadBundleJSON(name: "layer1-permissions", ext: "json")
            let added = mergePermissionsDeny(into: &settings, bundleData: permissionsBundle)
            layersApplied.append("layer1-permissions (+\(added) entries)")
        }

        // 4. Layer 1 sandbox (capture prior sandbox.enabled for marker)
        let priorSandboxEnabled: Any?
        if let sandboxDict = settings["sandbox"] as? [String: Any] {
            priorSandboxEnabled = sandboxDict["enabled"]
        } else {
            priorSandboxEnabled = nil
        }

        if options.layer1Sandbox {
            let sandboxBundle = try loadBundleJSON(name: "layer1-sandbox", ext: "json")
            mergeSandbox(into: &settings, bundleData: sandboxBundle)
            layersApplied.append("layer1-sandbox")
        }

        // 5. Layer 2: stage hook script files (atomic per-file replacement)
        if options.layer2Hooks {
            try installHookFiles()
            let hooksRegistration = try loadBundleJSON(name: "layer2-hooks-settings", ext: "json")
            let hooksDir = claudeDir.appendingPathComponent("hooks").path
            mergeHookRegistration(into: &settings, bundleData: hooksRegistration, hooksDir: hooksDir)
            layersApplied.append("layer2-hooks")
        }

        // 6. Layer 3: autoMode merge
        if options.layer3AutoMode {
            let automodeBundle = try loadBundleJSON(name: "layer3-automode", ext: "json")
            mergeAutoMode(into: &settings, bundleData: automodeBundle)
            layersApplied.append("layer3-automode")
        }

        // 7. Atomic write of settings.json (single replacement)
        try atomicWriteJSON(dict: settings, to: settingsURL)

        // 8. Layer 4: CLAUDE.md governance block (idempotent; strip+append+write)
        if options.layer4Governance {
            try installGovernanceBlock()
            layersApplied.append("layer4-governance")
        }

        // 9. Skill (atomic, checksum-verified)
        if options.skill {
            try installSkillFile()
            layersApplied.append("skill")
        }

        // 10. Marker (first-install-wins for backupPath + installedAt)
        try writeMarkerIfAbsent(
            installedAt: installStart,
            backupPath: backupDir,
            layersApplied: layersApplied,
            skillInstalled: options.skill,
            priorSandboxEnabled: priorSandboxEnabled
        )

        return HardeningInstallResult(
            installedAt: installStart,
            backupPath: backupDir,
            layersApplied: layersApplied,
            warnings: warnings
        )
    }

    /// Restore the user's pre-install state from this install's backup.
    /// Requires the marker file. If missing, throws `noMarkerForRevert` with a
    /// pointer toward Uninstall.
    func revert() async throws {
        await markInstallStart()
        defer { Task { await markInstallEnd() } }

        let markerURL = claudeDir.appendingPathComponent(Self.markerFileName)
        guard let marker = try? readMarker(at: markerURL) else {
            throw HardeningInstallError.noMarkerForRevert
        }

        let backupPathString = marker["backupPath"] as? String ?? ""
        let backupDir = URL(fileURLWithPath: backupPathString)
        let fm = FileManager.default

        // Restore settings.json from backup
        let backedSettings = backupDir.appendingPathComponent("settings.json")
        let liveSettings = claudeDir.appendingPathComponent("settings.json")
        if fm.fileExists(atPath: backedSettings.path) {
            try replaceFile(at: liveSettings, withContentsOf: backedSettings)
        }

        // Restore CLAUDE.md from backup
        let backedClaudeMd = backupDir.appendingPathComponent("CLAUDE.md")
        let liveClaudeMd = claudeDir.appendingPathComponent("CLAUDE.md")
        if fm.fileExists(atPath: backedClaudeMd.path) {
            try replaceFile(at: liveClaudeMd, withContentsOf: backedClaudeMd)
        }

        // Restore hooks/ dir state: delete our claudoscope-*.sh, restore any
        // backed-up files. We don't blow the live hooks/ dir away because users
        // may have added scripts since install.
        for hookName in Self.bundledHookScripts {
            let live = claudeDir.appendingPathComponent("hooks").appendingPathComponent(hookName)
            try? fm.removeItem(at: live)
        }
        let backupHooks = backupDir.appendingPathComponent("hooks")
        if fm.fileExists(atPath: backupHooks.path),
           let entries = try? fm.contentsOfDirectory(at: backupHooks, includingPropertiesForKeys: nil) {
            let liveHooks = claudeDir.appendingPathComponent("hooks")
            try? fm.createDirectory(at: liveHooks, withIntermediateDirectories: true)
            for src in entries {
                let dst = liveHooks.appendingPathComponent(src.lastPathComponent)
                try? fm.removeItem(at: dst)
                try? fm.copyItem(at: src, to: dst)
            }
        }

        // Restore skills/ state: delete only our skill file
        let liveSkill = claudeDir
            .appendingPathComponent("skills")
            .appendingPathComponent(Self.bundledSkillFile)
        try? fm.removeItem(at: liveSkill)

        // Delete marker
        try? fm.removeItem(at: markerURL)
    }

    /// Surgically remove every Claudoscope hardening artifact regardless of
    /// marker state. Safe to run repeatedly. If `deleteBackups` is true, also
    /// purges every `~/.claude/.claudoscope-hardening-backup-*` directory.
    func uninstall(deleteBackups: Bool) async throws {
        await markInstallStart()
        defer { Task { await markInstallEnd() } }

        let fm = FileManager.default
        let markerURL = claudeDir.appendingPathComponent(Self.markerFileName)
        let marker = try? readMarker(at: markerURL)

        // 1. settings.json: read once, strip our entries, write once
        let settingsURL = claudeDir.appendingPathComponent("settings.json")
        if fm.fileExists(atPath: settingsURL.path) {
            var settings = try readSettingsJSON(at: settingsURL)

            // 1a. Strip Layer 1 permissions baseline entries
            if let permissionsBundle = try? loadBundleJSON(name: "layer1-permissions", ext: "json") {
                stripPermissionsDeny(from: &settings, bundleData: permissionsBundle)
            }

            // 1b. Strip Layer 1 sandbox entries verbatim
            if let sandboxBundle = try? loadBundleJSON(name: "layer1-sandbox", ext: "json") {
                stripSandbox(from: &settings, bundleData: sandboxBundle, marker: marker)
            }

            // 1c. Strip Layer 2 hook registrations whose command basename is one of ours
            stripHookRegistrations(from: &settings)

            // 1d. Strip Layer 3 autoMode block ONLY IF byte-equal to our generic
            if let automodeBundle = try? loadBundleJSON(name: "layer3-automode", ext: "json") {
                stripAutoModeIfEqualToBaseline(from: &settings, bundleData: automodeBundle)
            }

            try atomicWriteJSON(dict: settings, to: settingsURL)
        }

        // 2. CLAUDE.md: strip the marker-wrapped governance block
        try stripGovernanceBlock()

        // 3. Delete bundled hook files
        let hooksDir = claudeDir.appendingPathComponent("hooks")
        for hookName in Self.bundledHookScripts {
            try? fm.removeItem(at: hooksDir.appendingPathComponent(hookName))
        }

        // 4. Delete the bundled skill
        let skillURL = claudeDir
            .appendingPathComponent("skills")
            .appendingPathComponent(Self.bundledSkillFile)
        try? fm.removeItem(at: skillURL)

        // 5. Optional backup cleanup
        if deleteBackups {
            try? deleteAllBackupDirectories()
        }

        // 6. Delete marker file
        try? fm.removeItem(at: markerURL)
    }

    // MARK: - Internal: install lifecycle gates

    private func markInstallStart() async {
        await MainActor.run { sessionStore.setInstallInProgress(true) }
    }

    private func markInstallEnd() async {
        await MainActor.run { sessionStore.setInstallInProgress(false) }
    }

    // MARK: - Internal: bundle access

    /// Look up a bundled resource. Returns nil when the resource is absent (e.g.
    /// before Wave 1 Agent A authors the files, or before Wave 2 Agent E wires
    /// them into project.yml/Package.swift). Caller turns nil into a clean
    /// `bundleResourceMissing` error.
    func loadBundleResource(name: String, ext: String, subdir: String? = nil) -> URL? {
        let resolvedSubdir = subdir ?? bundleSubdirectory
        return Bundle.main.url(forResource: name, withExtension: ext, subdirectory: resolvedSubdir)
    }

    private func loadBundleJSON(name: String, ext: String) throws -> [String: Any] {
        guard let url = loadBundleResource(name: name, ext: ext) else {
            throw HardeningInstallError.bundleResourceMissing("\(name).\(ext)")
        }
        do {
            let data = try Data(contentsOf: url)
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw HardeningInstallError.io("bundled \(name).\(ext) is not a JSON object")
            }
            return dict
        } catch let e as HardeningInstallError {
            throw e
        } catch {
            throw HardeningInstallError.io("failed to read bundled \(name).\(ext): \(error.localizedDescription)")
        }
    }

    private func loadBundleString(name: String, ext: String) throws -> String {
        guard let url = loadBundleResource(name: name, ext: ext) else {
            throw HardeningInstallError.bundleResourceMissing("\(name).\(ext)")
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw HardeningInstallError.io("failed to read bundled \(name).\(ext): \(error.localizedDescription)")
        }
    }

    // MARK: - Internal: settings.json IO

    /// Read settings.json. Returns an empty dict if the file doesn't exist
    /// (fresh install). Throws `malformedSettingsJson` on parse failure rather
    /// than silently overwriting the user's hand-edited file.
    private func readSettingsJSON(at url: URL) throws -> [String: Any] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return [:] }
        do {
            let data = try Data(contentsOf: url)
            // Empty file is a degenerate but valid case
            if data.isEmpty { return [:] }
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw HardeningInstallError.malformedSettingsJson
            }
            return dict
        } catch let e as HardeningInstallError {
            throw e
        } catch {
            throw HardeningInstallError.malformedSettingsJson
        }
    }

    /// Write a dict as pretty-printed JSON with deterministic key ordering.
    /// Uses staging file + fsync + `replaceItemAt(...)` to ensure FSEvents only
    /// observes the final, complete file.
    private func atomicWriteJSON(dict: [String: Any], to url: URL) throws {
        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: dict,
                options: [.prettyPrinted, .sortedKeys]
            )
        } catch {
            throw HardeningInstallError.io("JSON serialization failed: \(error.localizedDescription)")
        }
        try atomicWrite(data: data, to: url)
    }

    /// Atomic file write helper used by both JSON and text content. Stages to
    /// `<final>.tmp-<uuid>`, fsyncs, then `replaceItemAt(...)`.
    private func atomicWrite(data: Data, to url: URL) throws {
        let fm = FileManager.default
        try? fm.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let tmpName = "\(url.lastPathComponent).tmp-\(UUID().uuidString)"
        let tmpURL = url.deletingLastPathComponent().appendingPathComponent(tmpName)

        do {
            try data.write(to: tmpURL, options: [.atomic])
        } catch {
            throw HardeningInstallError.io("failed to write staging file \(tmpURL.path): \(error.localizedDescription)")
        }

        // Best-effort fsync: open the file and call fsync on the descriptor.
        // We don't fail the install if fsync fails — Data.write(.atomic) above
        // already handles the durability concern most of the time.
        if let handle = try? FileHandle(forUpdating: tmpURL) {
            try? handle.synchronize()
            try? handle.close()
        }

        // replaceItemAt requires the destination to exist; if not, just rename.
        if fm.fileExists(atPath: url.path) {
            do {
                _ = try fm.replaceItemAt(url, withItemAt: tmpURL)
            } catch {
                try? fm.removeItem(at: tmpURL)
                throw HardeningInstallError.io("failed to replace \(url.path): \(error.localizedDescription)")
            }
        } else {
            do {
                try fm.moveItem(at: tmpURL, to: url)
            } catch {
                try? fm.removeItem(at: tmpURL)
                throw HardeningInstallError.io("failed to install \(url.path): \(error.localizedDescription)")
            }
        }
    }

    /// Replace a file by copying source contents over. Used by revert.
    private func replaceFile(at dst: URL, withContentsOf src: URL) throws {
        let data = try Data(contentsOf: src)
        try atomicWrite(data: data, to: dst)
    }

    // MARK: - Internal: backup

    private func createBackup() throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stamp = formatter.string(from: Date())

        let backupDir = claudeDir.appendingPathComponent(".claudoscope-hardening-backup-\(stamp)")
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        } catch {
            throw HardeningInstallError.io("failed to create backup dir \(backupDir.path): \(error.localizedDescription)")
        }

        let settingsSrc = claudeDir.appendingPathComponent("settings.json")
        if fm.fileExists(atPath: settingsSrc.path) {
            try? fm.copyItem(at: settingsSrc, to: backupDir.appendingPathComponent("settings.json"))
        }

        let claudeMdSrc = claudeDir.appendingPathComponent("CLAUDE.md")
        if fm.fileExists(atPath: claudeMdSrc.path) {
            try? fm.copyItem(at: claudeMdSrc, to: backupDir.appendingPathComponent("CLAUDE.md"))
        }

        let hooksSrc = claudeDir.appendingPathComponent("hooks")
        if fm.fileExists(atPath: hooksSrc.path) {
            try? fm.copyItem(at: hooksSrc, to: backupDir.appendingPathComponent("hooks"))
        }

        return backupDir
    }

    private func deleteAllBackupDirectories() throws {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: claudeDir, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(".claudoscope-hardening-backup-") {
            try? fm.removeItem(at: entry)
        }
    }

    // MARK: - Internal: Layer 1 permissions

    /// Union the bundled `permissions.deny` list into the live settings dict.
    /// Returns the count of newly added entries (for telemetry/UI).
    func mergePermissionsDeny(into settings: inout [String: Any], bundleData: [String: Any]) -> Int {
        var permissions = (settings["permissions"] as? [String: Any]) ?? [:]
        var deny = (permissions["deny"] as? [String]) ?? []
        let bundlePerms = (bundleData["permissions"] as? [String: Any]) ?? [:]
        let bundleDeny = (bundlePerms["deny"] as? [String]) ?? []

        var seen = Set(deny)
        var added = 0
        for entry in bundleDeny where !seen.contains(entry) {
            deny.append(entry)
            seen.insert(entry)
            added += 1
        }
        permissions["deny"] = deny
        settings["permissions"] = permissions
        return added
    }

    private func stripPermissionsDeny(from settings: inout [String: Any], bundleData: [String: Any]) {
        guard var permissions = settings["permissions"] as? [String: Any],
              var deny = permissions["deny"] as? [String] else { return }
        let bundleDeny = Set((bundleData["permissions"] as? [String: Any])?["deny"] as? [String] ?? [])
        deny.removeAll { bundleDeny.contains($0) }
        permissions["deny"] = deny
        settings["permissions"] = permissions
    }

    // MARK: - Internal: Layer 1 sandbox

    /// Set sandbox.enabled = true and union the bundled denyRead/denyWrite/
    /// allowedHosts arrays into the live config. Never overwrites user entries.
    func mergeSandbox(into settings: inout [String: Any], bundleData: [String: Any]) {
        var sandbox = (settings["sandbox"] as? [String: Any]) ?? [:]
        sandbox["enabled"] = true

        var filesystem = (sandbox["filesystem"] as? [String: Any]) ?? [:]
        var network = (sandbox["network"] as? [String: Any]) ?? [:]

        let bundleSandbox = (bundleData["sandbox"] as? [String: Any]) ?? [:]
        let bundleFs = (bundleSandbox["filesystem"] as? [String: Any]) ?? [:]
        let bundleNet = (bundleSandbox["network"] as? [String: Any]) ?? [:]

        filesystem["denyRead"] = unionStringArray(
            existing: filesystem["denyRead"] as? [String] ?? [],
            additions: bundleFs["denyRead"] as? [String] ?? []
        )
        filesystem["denyWrite"] = unionStringArray(
            existing: filesystem["denyWrite"] as? [String] ?? [],
            additions: bundleFs["denyWrite"] as? [String] ?? []
        )
        network["allowedHosts"] = unionStringArray(
            existing: network["allowedHosts"] as? [String] ?? [],
            additions: bundleNet["allowedHosts"] as? [String] ?? []
        )

        sandbox["filesystem"] = filesystem
        sandbox["network"] = network
        settings["sandbox"] = sandbox
    }

    private func stripSandbox(
        from settings: inout [String: Any],
        bundleData: [String: Any],
        marker: [String: Any]?
    ) {
        guard var sandbox = settings["sandbox"] as? [String: Any] else { return }
        let bundleSandbox = (bundleData["sandbox"] as? [String: Any]) ?? [:]
        let bundleFs = (bundleSandbox["filesystem"] as? [String: Any]) ?? [:]
        let bundleNet = (bundleSandbox["network"] as? [String: Any]) ?? [:]

        var filesystem = (sandbox["filesystem"] as? [String: Any]) ?? [:]
        var network = (sandbox["network"] as? [String: Any]) ?? [:]

        if let denyRead = filesystem["denyRead"] as? [String] {
            let toRemove = Set(bundleFs["denyRead"] as? [String] ?? [])
            filesystem["denyRead"] = denyRead.filter { !toRemove.contains($0) }
        }
        if let denyWrite = filesystem["denyWrite"] as? [String] {
            let toRemove = Set(bundleFs["denyWrite"] as? [String] ?? [])
            filesystem["denyWrite"] = denyWrite.filter { !toRemove.contains($0) }
        }
        if let allowed = network["allowedHosts"] as? [String] {
            let toRemove = Set(bundleNet["allowedHosts"] as? [String] ?? [])
            network["allowedHosts"] = allowed.filter { !toRemove.contains($0) }
        }

        sandbox["filesystem"] = filesystem
        sandbox["network"] = network

        // sandbox.enabled: change to false ONLY IF marker says we set it (i.e.
        // the prior value was missing/false). Otherwise leave untouched.
        if let prior = marker?["priorSandboxEnabled"] {
            // Marker stored the prior value: NSNull, false, or true.
            if prior is NSNull {
                sandbox["enabled"] = false
            } else if let b = prior as? Bool, b == false {
                sandbox["enabled"] = false
            }
            // If prior was true, leave it.
        }
        // If no marker, do nothing — safer default.

        settings["sandbox"] = sandbox
    }

    // MARK: - Internal: Layer 2 hooks

    /// Stage each bundled hook script under `hooks/.staging-<uuid>/<filename>`,
    /// chmod 0755, SHA-256 verify against bundled sidecar, then atomic rename
    /// into final position. Aborts the entire install on checksum mismatch
    /// (corrupted bundle) without partial-state damage.
    func installHookFiles() throws {
        let fm = FileManager.default
        let hooksDir = claudeDir.appendingPathComponent("hooks")
        try? fm.createDirectory(at: hooksDir, withIntermediateDirectories: true)

        let stagingDir = hooksDir.appendingPathComponent(".staging-\(UUID().uuidString)")
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingDir) }

        // Load expected checksums
        let checksumString = try loadBundleString(name: "layer2-hooks", ext: "sha256")
        let expected = parseChecksumSidecar(content: checksumString)

        for name in Self.bundledHookScripts {
            let bundleScript = name.replacingOccurrences(of: ".sh", with: "")
            guard let srcURL = loadBundleResource(
                name: bundleScript,
                ext: "sh",
                subdir: "\(bundleSubdirectory)/layer2-hooks"
            ) else {
                throw HardeningInstallError.bundleResourceMissing(name)
            }

            let stagedURL = stagingDir.appendingPathComponent(name)
            try fm.copyItem(at: srcURL, to: stagedURL)

            try fm.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: stagedURL.path)

            let actual = try sha256(file: stagedURL)
            if let want = expected[name], want.lowercased() != actual.lowercased() {
                throw HardeningInstallError.checksumMismatch(name)
            }

            let finalURL = hooksDir.appendingPathComponent(name)
            try moveOrReplace(from: stagedURL, to: finalURL)
        }
    }

    /// Merge bundled hook registration entries into `settings.hooks.*`.
    /// `__HOOKS_DIR__` placeholder in the bundle is replaced with the absolute
    /// hooks directory path. Dedupes by `(matcher, command)` tuple so reinstalls
    /// stay idempotent.
    func mergeHookRegistration(
        into settings: inout [String: Any],
        bundleData: [String: Any],
        hooksDir: String
    ) {
        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]
        let bundleHooks = (bundleData["hooks"] as? [String: Any]) ?? [:]

        for (event, value) in bundleHooks {
            guard let bundleEntries = value as? [[String: Any]] else { continue }
            var existing = (hooks[event] as? [[String: Any]]) ?? []

            // Build set of (matcher, command) tuples already present
            var existingPairs: Set<String> = []
            for entry in existing {
                let matcher = entry["matcher"] as? String ?? "*"
                let inner = (entry["hooks"] as? [[String: Any]]) ?? []
                for h in inner {
                    let cmd = h["command"] as? String ?? ""
                    existingPairs.insert("\(matcher)\u{1F}\(cmd)")
                }
            }

            for bundleEntry in bundleEntries {
                let matcher = bundleEntry["matcher"] as? String ?? "*"
                let inner = (bundleEntry["hooks"] as? [[String: Any]]) ?? []
                let expanded: [[String: Any]] = inner.compactMap { hookDict in
                    var copy = hookDict
                    if let cmd = copy["command"] as? String {
                        let resolved = cmd.replacingOccurrences(of: "__HOOKS_DIR__", with: hooksDir)
                        copy["command"] = resolved
                    }
                    let cmdStr = copy["command"] as? String ?? ""
                    let key = "\(matcher)\u{1F}\(cmdStr)"
                    if existingPairs.contains(key) { return nil }
                    existingPairs.insert(key)
                    return copy
                }
                if !expanded.isEmpty {
                    var newEntry = bundleEntry
                    newEntry["hooks"] = expanded
                    existing.append(newEntry)
                }
            }
            hooks[event] = existing
        }
        settings["hooks"] = hooks
    }

    /// Strip every hook entry whose command basename matches one of our bundled
    /// `claudoscope-*.sh` filenames. User-authored hooks are untouched.
    private func stripHookRegistrations(from settings: inout [String: Any]) {
        guard var hooks = settings["hooks"] as? [String: Any] else { return }
        let bundledNames = Set(Self.bundledHookScripts)

        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            var rebuilt: [[String: Any]] = []
            for entry in entries {
                let inner = (entry["hooks"] as? [[String: Any]]) ?? []
                let kept = inner.filter { hookDict in
                    let cmd = hookDict["command"] as? String ?? ""
                    let basename = (cmd as NSString).lastPathComponent
                    return !bundledNames.contains(basename)
                }
                if !kept.isEmpty {
                    var newEntry = entry
                    newEntry["hooks"] = kept
                    rebuilt.append(newEntry)
                }
            }
            hooks[event] = rebuilt
        }
        settings["hooks"] = hooks
    }

    // MARK: - Internal: Layer 3 autoMode

    /// Mirrors `install.sh:348-372`: skip permissions/hooks/_comment top-level
    /// keys; for autoMode and other dicts, deep-merge environment and soft_deny
    /// arrays by union.
    func mergeAutoMode(into settings: inout [String: Any], bundleData: [String: Any]) {
        let skipKeys: Set<String> = ["permissions", "hooks", "_comment"]
        for (key, value) in bundleData where !skipKeys.contains(key) {
            if key == "autoMode", var existing = settings["autoMode"] as? [String: Any],
               let bundleAutoMode = value as? [String: Any] {
                for (subKey, subValue) in bundleAutoMode {
                    if let existingArr = existing[subKey] as? [String],
                       let bundleArr = subValue as? [String] {
                        existing[subKey] = unionStringArray(existing: existingArr, additions: bundleArr)
                    } else if let existingDict = existing[subKey] as? [String: Any],
                              let bundleDict = subValue as? [String: Any] {
                        var merged = existingDict
                        for (k, v) in bundleDict { merged[k] = v }
                        existing[subKey] = merged
                    } else {
                        existing[subKey] = subValue
                    }
                }
                settings["autoMode"] = existing
            } else if let existing = settings[key] as? [String: Any], let bundleDict = value as? [String: Any] {
                var merged = existing
                for (k, v) in bundleDict { merged[k] = v }
                settings[key] = merged
            } else {
                settings[key] = value
            }
        }
    }

    /// Drop autoMode block ONLY IF byte-equal to bundled baseline. This is a
    /// conservative test: any user-added entry blocks the strip and the user
    /// needs to clean up manually.
    private func stripAutoModeIfEqualToBaseline(from settings: inout [String: Any], bundleData: [String: Any]) {
        guard let live = settings["autoMode"] as? [String: Any],
              let bundleAutoMode = bundleData["autoMode"] as? [String: Any] else { return }
        if dictsEqual(live, bundleAutoMode) {
            settings.removeValue(forKey: "autoMode")
        }
    }

    // MARK: - Internal: Layer 4 governance

    /// Idempotent governance block install: read CLAUDE.md, strip any existing
    /// claudoscope-hardening block, append fresh block, atomic write.
    private func installGovernanceBlock() throws {
        let bundleBody = try loadBundleString(name: "layer4-governance", ext: "md")
        let claudeMdURL = claudeDir.appendingPathComponent("CLAUDE.md")

        var existing = ""
        if let data = try? Data(contentsOf: claudeMdURL),
           let text = String(data: data, encoding: .utf8) {
            existing = text
        }

        let stripped = stripGovernance(from: existing)

        // Compose: stripped (trimmed of trailing newlines) + blank line + block
        let trimmed = stripped.trimmingCharacters(in: .newlines)
        let block = "\n\n\(Self.governanceBeginMarker)\n\(bundleBody)\n\(Self.governanceEndMarker)\n"
        let final = trimmed + block

        guard let data = final.data(using: .utf8) else {
            throw HardeningInstallError.io("UTF-8 encoding of CLAUDE.md failed")
        }
        try atomicWrite(data: data, to: claudeMdURL)
    }

    private func stripGovernanceBlock() throws {
        let claudeMdURL = claudeDir.appendingPathComponent("CLAUDE.md")
        let fm = FileManager.default
        guard fm.fileExists(atPath: claudeMdURL.path),
              let data = try? Data(contentsOf: claudeMdURL),
              let text = String(data: data, encoding: .utf8) else { return }
        let cleaned = stripGovernance(from: text)
        if cleaned == text { return }  // nothing to strip
        guard let out = cleaned.data(using: .utf8) else { return }
        try atomicWrite(data: out, to: claudeMdURL)
    }

    /// Remove the marker-wrapped block from a CLAUDE.md body, including the
    /// markers themselves and one leading newline if present.
    func stripGovernance(from text: String) -> String {
        let begin = Self.governanceBeginMarker
        let end = Self.governanceEndMarker

        guard let beginRange = text.range(of: begin),
              let endRange = text.range(of: end, range: beginRange.upperBound..<text.endIndex) else {
            return text
        }

        // Extend the start back to consume the leading blank lines we inserted
        var start = beginRange.lowerBound
        while start > text.startIndex {
            let prev = text.index(before: start)
            if text[prev] == "\n" { start = prev } else { break }
        }
        // Extend the end forward over a trailing newline if present
        var stop = endRange.upperBound
        if stop < text.endIndex, text[stop] == "\n" {
            stop = text.index(after: stop)
        }

        var result = text
        result.removeSubrange(start..<stop)
        return result
    }

    // MARK: - Internal: skill

    /// Install `claudoscope-security-awareness.md` into `~/.claude/skills/`
    /// using the same staging + checksum-verify + atomic-rename pattern as
    /// hooks. Creates `~/.claude/skills/` (mode 0755) if absent.
    func installSkillFile() throws {
        let fm = FileManager.default
        let skillsDir = claudeDir.appendingPathComponent("skills")
        if !fm.fileExists(atPath: skillsDir.path) {
            try fm.createDirectory(at: skillsDir, withIntermediateDirectories: true)
            try? fm.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: skillsDir.path)
        }

        let stagingDir = skillsDir.appendingPathComponent(".staging-\(UUID().uuidString)")
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingDir) }

        let baseName = (Self.bundledSkillFile as NSString).deletingPathExtension
        guard let srcURL = loadBundleResource(name: baseName, ext: "md", subdir: "\(bundleSubdirectory)/skills") else {
            throw HardeningInstallError.bundleResourceMissing(Self.bundledSkillFile)
        }

        let stagedURL = stagingDir.appendingPathComponent(Self.bundledSkillFile)
        try fm.copyItem(at: srcURL, to: stagedURL)
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: stagedURL.path)

        // Verify checksum if sidecar exists in bundle
        if let sidecarURL = loadBundleResource(name: baseName, ext: "sha256", subdir: "\(bundleSubdirectory)/skills"),
           let sidecarText = try? String(contentsOf: sidecarURL, encoding: .utf8) {
            let expected = parseChecksumSidecar(content: sidecarText)
            let actual = try sha256(file: stagedURL)
            // Sidecar may key by the .md filename or by basename; check both.
            let want = expected[Self.bundledSkillFile] ?? expected[baseName]
            if let want, want.lowercased() != actual.lowercased() {
                throw HardeningInstallError.checksumMismatch(Self.bundledSkillFile)
            }
        }

        let finalURL = skillsDir.appendingPathComponent(Self.bundledSkillFile)
        try moveOrReplace(from: stagedURL, to: finalURL)
    }

    // MARK: - Internal: marker

    /// Write the install marker, but only if absent. If present, reread it and
    /// preserve `installedAt`/`backupPath` so revert always points at the true
    /// pre-install state. Other fields (layersApplied, skillInstalled,
    /// priorSandboxEnabled) are refreshed from the current install run.
    func writeMarkerIfAbsent(
        installedAt: Date,
        backupPath: URL,
        layersApplied: [String],
        skillInstalled: Bool,
        priorSandboxEnabled: Any?
    ) throws {
        let url = claudeDir.appendingPathComponent(Self.markerFileName)
        let fm = FileManager.default

        // Decide which installedAt + backupPath to record.
        var effectiveInstalledAt = installedAt
        var effectiveBackupPath = backupPath
        var effectivePriorSandbox: Any? = priorSandboxEnabled

        if fm.fileExists(atPath: url.path), let existing = try? readMarker(at: url) {
            if let prior = existing["installedAt"] as? String,
               let parsed = isoFormatter.date(from: prior) {
                effectiveInstalledAt = parsed
            }
            if let prior = existing["backupPath"] as? String {
                effectiveBackupPath = URL(fileURLWithPath: prior)
            }
            // Preserve original priorSandboxEnabled too, since it captures the
            // truly-original pre-first-install state.
            if let priorVal = existing["priorSandboxEnabled"] {
                effectivePriorSandbox = priorVal
            }
        }

        var marker: [String: Any] = [
            "version": "1",
            "installedAt": isoFormatter.string(from: effectiveInstalledAt),
            "backupPath": effectiveBackupPath.path,
            "layersApplied": layersApplied,
            "skillInstalled": skillInstalled,
        ]
        // Encode prior sandbox value: true, false, or NSNull for missing
        if let prior = effectivePriorSandbox {
            marker["priorSandboxEnabled"] = prior
        } else {
            marker["priorSandboxEnabled"] = NSNull()
        }

        try atomicWriteJSON(dict: marker, to: url)
    }

    private func readMarker(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HardeningInstallError.io("marker file is not a JSON object: \(url.path)")
        }
        return dict
    }

    // MARK: - Internal: helpers

    func sha256(file url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Parse a `shasum -a 256` sidecar: lines of the form
    /// `<hex>  <filename>` (two spaces). Tolerates blank lines and CRLF.
    func parseChecksumSidecar(content: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in content.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            // Match "<hex> <maybe-asterisk><filename>"
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2 else { continue }
            let hex = String(parts[0])
            // shasum format places "*" before the name in binary mode; strip it
            var name = String(parts[1...].joined(separator: " "))
            if name.hasPrefix("*") { name.removeFirst() }
            // strip any leading "./"
            if name.hasPrefix("./") { name = String(name.dropFirst(2)) }
            // strip a path prefix and keep only the basename for matching
            let basename = (name as NSString).lastPathComponent
            out[basename] = hex
        }
        return out
    }

    func parseChecksumSidecar(at url: URL) throws -> [String: String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return parseChecksumSidecar(content: text)
    }

    private func unionStringArray(existing: [String], additions: [String]) -> [String] {
        var seen = Set(existing)
        var result = existing
        for a in additions where !seen.contains(a) {
            result.append(a)
            seen.insert(a)
        }
        return result
    }

    /// Recursive equality on [String: Any] dicts using JSONSerialization data
    /// comparison with sorted keys. Cheap, deterministic, and tolerant of
    /// numeric/boolean type variation.
    private func dictsEqual(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        guard let dataA = try? JSONSerialization.data(withJSONObject: a, options: [.sortedKeys]),
              let dataB = try? JSONSerialization.data(withJSONObject: b, options: [.sortedKeys]) else {
            return false
        }
        return dataA == dataB
    }

    private func moveOrReplace(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dst.path) {
            do {
                _ = try fm.replaceItemAt(dst, withItemAt: src)
            } catch {
                throw HardeningInstallError.io("failed to replace \(dst.path): \(error.localizedDescription)")
            }
        } else {
            do {
                try fm.moveItem(at: src, to: dst)
            } catch {
                throw HardeningInstallError.io("failed to install \(dst.path): \(error.localizedDescription)")
            }
        }
    }

    private var isoFormatter: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }
}
